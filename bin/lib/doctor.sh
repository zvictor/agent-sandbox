doctor_line() {
  local key="$1"
  local value="$2"
  printf '%-24s %s\n' "$key" "$value"
}

doctor_note() {
  printf -- '- %s\n' "$1"
}

doctor_path_state() {
  local path="$1"

  if [ -S "$path" ]; then
    printf 'present (%s)\n' "$path"
  elif [ -e "$path" ]; then
    printf 'present (%s)\n' "$path"
  else
    printf 'missing (%s)\n' "$path"
  fi
}

doctor_profile_state() {
  local profile_name="$1"
  local profile_path="$2"

  if [ -z "$profile_name" ]; then
    printf 'unset\n'
  elif [ -f "$profile_path" ]; then
    printf '%s (%s)\n' "$profile_name" "$profile_path"
  else
    printf '%s (missing: %s)\n' "$profile_name" "$profile_path"
  fi
}

doctor_contract_source() {
  if [ -f "$PROJECT_NIX_DIR/packages.nix" ]; then
    printf '%s\n' "$PROJECT_NIX_DIR/packages.nix"
  elif [ -f "$PROJECT_ROOT/shell.nix" ]; then
    printf '%s\n' "$PROJECT_ROOT/shell.nix"
  else
    printf 'built-in empty project contract\n'
  fi
}

doctor_runtime_mode() {
  local runtime_mode=""

  if [ "$RUNTIME" = "unavailable" ]; then
    printf 'unavailable: neither podman nor docker is installed\n'
    return 0
  fi

  if [ "$RUNTIME" = "podman" ]; then
    if [ "$OS_NAME" != "Linux" ]; then
      printf 'unavailable: podman rootfs requires Linux\n'
      return 0
    fi
    if [ ! -d /nix/store ]; then
      printf 'unavailable: /nix/store missing on host\n'
      return 0
    fi
    if [ -n "${CONTAINER_HOST:-}" ]; then
      printf 'unavailable: CONTAINER_HOST is set\n'
      return 0
    fi

    runtime_mode="podman-rootfs"
    if command -v podman >/dev/null 2>&1; then
      runtime_mode="$runtime_mode ($(detect_podman_rootfs_mode))"
    fi
    printf '%s\n' "$runtime_mode"
    return 0
  fi

  printf 'docker-oci\n'
}

resolve_runtime_for_doctor() {
  RUNTIME="${AGENT_RUNTIME:-${CODEX_RUNTIME:-}}"
  if [ -n "$RUNTIME" ] && command -v "$RUNTIME" >/dev/null 2>&1; then
    return 0
  fi

  if command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
  else
    RUNTIME="unavailable"
  fi
}

print_doctor_suggestions() {
  local printed="0"
  local target_config=""

  if [ -z "${PROJECT_CONFIG_FILE:-}" ]; then
    doctor_note "Run 'agent init' to create a project defaults file under $PROJECT_NIX_DIR/agent-sandbox.env."
    printed="1"
  fi

  if [ "$RUNTIME" = "unavailable" ]; then
    doctor_note "Install podman for the preferred Linux fast path, or docker for the OCI image fallback path."
    printed="1"
  fi

  if [ "${AGENT_CONTAINER_API:-}" = "auto" ] && [ "$CONTAINER_API_MODE" = "none" ]; then
    doctor_note "Container API auto mode fell back to 'none'. Install or fix host podman if you want Testcontainers support."
    printed="1"
  fi

  if [ "${AGENT_CONTAINER_API:-}" = "podman-session" ] && [ "$CONTAINER_API_MODE" = "podman-session" ] && [ "$RUNTIME" = "unavailable" ]; then
    doctor_note "Podman session mode is requested, but no usable runtime was detected. Install podman on the host first."
    printed="1"
  fi

  if [ "${AGENT_DEV_ENV:-host-helper}" = "host-helper" ] && [ ! -f "$PROJECT_ROOT/.envrc" ]; then
    doctor_note "No .envrc was found, so the host direnv snapshot helper is currently idle."
    printed="1"
  fi

  if [ -n "${CODEX_PROFILE:-}" ] && [ ! -f "$CODEX_PROFILE_BASE/${CODEX_PROFILE}.json" ]; then
    doctor_note "Create the Codex profile file at $CODEX_PROFILE_BASE/${CODEX_PROFILE}.json or unset CODEX_PROFILE."
    printed="1"
  fi

  if [ -n "${CLAUDE_PROFILE:-}" ] && [ ! -f "$CLAUDE_PROFILE_BASE/${CLAUDE_PROFILE}.json" ]; then
    doctor_note "Create the Claude profile file at $CLAUDE_PROFILE_BASE/${CLAUDE_PROFILE}.json or unset CLAUDE_PROFILE."
    printed="1"
  fi

  if [ -n "${OPENCODE_PROFILE:-}" ] && [ ! -f "$OPENCODE_PROFILE_BASE/${OPENCODE_PROFILE}.json" ]; then
    doctor_note "Create the OpenCode profile file at $OPENCODE_PROFILE_BASE/${OPENCODE_PROFILE}.json or unset OPENCODE_PROFILE."
    printed="1"
  fi

  if [ "$NIX_TOOL_HELPER_MODE" = "0" ]; then
    doctor_note "Set AGENT_NIX_TOOL_HELPER=1 if you want standard commands like 'nix shell nixpkgs#jq --command jq --version' to use the narrow host-backed tool path."
    printed="1"
  fi

  if [ "$printed" = "0" ]; then
    doctor_note "No obvious setup problems detected. If behavior is still surprising, rerun with AGENT_DEBUG=1 for the launcher trace."
  fi
}

print_doctor_and_exit() {
  local requested_container_api=""
  local runtime_mode=""
  local tools_list=""
  local runtime_dir=""
  local podman_socket_path=""
  local docker_socket_path="/var/run/docker.sock"
  local nix_daemon_socket_path="/nix/var/nix/daemon-socket/socket"

  resolve_project_paths
  load_project_config
  resolve_runtime_for_doctor
  resolve_sandbox_flake
  resolve_lock_args
  resolve_host_home
  prepare_project_contract_input
  prepare_cache_dirs
  resolve_direnv_nix_path
  resolve_container_api_mode
  resolve_nix_tool_helper_mode
  resolve_tool_config_roots

  requested_container_api="${AGENT_CONTAINER_API:-}"
  if [ -z "$requested_container_api" ]; then
    if [ "${AGENT_ALLOW_PODMAN_SOCKET:-0}" = "1" ]; then
      requested_container_api="podman-host (legacy)"
    elif [ "${AGENT_ALLOW_DOCKER_SOCKET:-0}" = "1" ]; then
      requested_container_api="docker-host (legacy)"
    else
      requested_container_api="none"
    fi
  fi

  tools_list="${AGENT_TOOLS:-$KNOWN_TOOLS}"
  runtime_mode="$(doctor_runtime_mode)"
  runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  podman_socket_path="$runtime_dir/podman/podman.sock"

  printf 'Agent Sandbox Doctor\n\n'

  printf 'Project\n'
  doctor_line "project_root" "$PROJECT_ROOT"
  doctor_line "project_nix_dir" "$PROJECT_NIX_DIR"
  doctor_line "project_config" "${PROJECT_CONFIG_FILE:-none}"
  doctor_line "project_contract" "$(doctor_contract_source)"
  doctor_line "sandbox_flake" "$SANDBOX_FLAKE"

  printf '\nRuntime\n'
  doctor_line "runtime" "$RUNTIME"
  doctor_line "runtime_mode" "$runtime_mode"
  doctor_line "tools_enabled" "$tools_list"

  printf '\nCapabilities\n'
  doctor_line "container_api.requested" "$requested_container_api"
  doctor_line "container_api.resolved" "$CONTAINER_API_MODE"
  doctor_line "nix_tool_helper" "$NIX_TOOL_HELPER_MODE"
  doctor_line "dev_env_mode" "${AGENT_DEV_ENV:-host-helper}"
  doctor_line "direnv_file" "$(doctor_path_state "$PROJECT_ROOT/.envrc")"
  doctor_line "direnv_nix_path" "${AGENT_DIRENV_NIX_PATH:-unset}"

  printf '\nSockets\n'
  doctor_line "podman_host_socket" "$(doctor_path_state "$podman_socket_path")"
  doctor_line "docker_host_socket" "$(doctor_path_state "$docker_socket_path")"
  doctor_line "nix_daemon_socket" "$(doctor_path_state "$nix_daemon_socket_path")"

  printf '\nTool Config\n'
  doctor_line "codex_config" "$(doctor_path_state "$CODEX_HOST_CONFIG")"
  doctor_line "codex_profile" "$(doctor_profile_state "${CODEX_PROFILE:-}" "$CODEX_PROFILE_BASE/${CODEX_PROFILE:-}.json")"
  doctor_line "claude_config" "$(doctor_path_state "$CLAUDE_HOST_CONFIG")"
  doctor_line "claude_profile" "$(doctor_profile_state "${CLAUDE_PROFILE:-}" "$CLAUDE_PROFILE_BASE/${CLAUDE_PROFILE:-}.json")"
  doctor_line "opencode_config" "$(doctor_path_state "$OPENCODE_HOST_CONFIG")"
  doctor_line "opencode_profile" "$(doctor_profile_state "${OPENCODE_PROFILE:-}" "$OPENCODE_PROFILE_BASE/${OPENCODE_PROFILE:-}.json")"
  doctor_line "omp_config" "$(doctor_path_state "$OMP_HOST_CONFIG")"

  printf '\nSuggested next steps\n'
  print_doctor_suggestions

  exit 0
}
