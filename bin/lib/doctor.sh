DOCTOR_OUTPUT="text"
DOCTOR_VERBOSE="0"

doctor_line() {
  local key="$1"
  local value="$2"
  printf '%-24s %s\n' "$key" "$value"
}

doctor_note() {
  printf -- '- %s\n' "$1"
}

resolve_doctor_args() {
  DOCTOR_OUTPUT="text"
  DOCTOR_VERBOSE="0"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)
        DOCTOR_OUTPUT="json"
        ;;
      --verbose)
        DOCTOR_VERBOSE="1"
        ;;
      *)
        echo "usage: agent doctor [--json] [--verbose]" >&2
        exit 1
        ;;
    esac
    shift
  done
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

doctor_json_escape() {
  printf '%s' "$1" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/"/\\"/g' \
    -e 's/	/\\t/g' \
    -e 's//\\r/g'
}

doctor_json_pair() {
  local key="$1"
  local value="$2"
  printf '    "%s": "%s"' "$(doctor_json_escape "$key")" "$(doctor_json_escape "$value")"
}

print_doctor_json() {
  local requested_container_api="$1"
  local runtime_mode="$2"
  local tools_list="$3"
  local podman_socket_state="$4"
  local docker_socket_state="$5"
  local nix_daemon_socket_state="$6"
  local codex_config_state="$7"
  local codex_profile_state="$8"
  local claude_config_state="$9"
  local claude_profile_state="${10}"
  local opencode_config_state="${11}"
  local opencode_profile_state="${12}"
  local omp_config_state="${13}"
  local suggestions="${14}"

  printf '{\n'
  printf '  "project": {\n'
  doctor_json_pair "root" "$PROJECT_ROOT"; printf ',\n'
  doctor_json_pair "nix_dir" "$PROJECT_NIX_DIR"; printf ',\n'
  doctor_json_pair "config_file" "${PROJECT_CONFIG_FILE:-none}"; printf ',\n'
  doctor_json_pair "contract" "$(doctor_contract_source)"; printf ',\n'
  doctor_json_pair "sandbox_flake" "$SANDBOX_FLAKE"; printf '\n'
  printf '  },\n'
  printf '  "runtime": {\n'
  doctor_json_pair "runtime" "$RUNTIME"; printf ',\n'
  doctor_json_pair "mode" "$runtime_mode"; printf ',\n'
  doctor_json_pair "tools_enabled" "$tools_list"; printf '\n'
  printf '  },\n'
  printf '  "capabilities": {\n'
  doctor_json_pair "container_api_requested" "$requested_container_api"; printf ',\n'
  doctor_json_pair "container_api_resolved" "$CONTAINER_API_MODE"; printf ',\n'
  doctor_json_pair "nix_tool_helper" "$NIX_TOOL_HELPER_MODE"; printf ',\n'
  doctor_json_pair "dev_env_mode" "${AGENT_DEV_ENV:-host-helper}"; printf ',\n'
  doctor_json_pair "direnv_file" "$(doctor_path_state "$PROJECT_ROOT/.envrc")"; printf ',\n'
  doctor_json_pair "direnv_nix_path" "${AGENT_DIRENV_NIX_PATH:-unset}"; printf '\n'
  printf '  },\n'
  printf '  "sockets": {\n'
  doctor_json_pair "podman_host_socket" "$podman_socket_state"; printf ',\n'
  doctor_json_pair "docker_host_socket" "$docker_socket_state"; printf ',\n'
  doctor_json_pair "nix_daemon_socket" "$nix_daemon_socket_state"; printf '\n'
  printf '  },\n'
  printf '  "tool_config": {\n'
  doctor_json_pair "codex_config" "$codex_config_state"; printf ',\n'
  doctor_json_pair "codex_profile" "$codex_profile_state"; printf ',\n'
  doctor_json_pair "claude_config" "$claude_config_state"; printf ',\n'
  doctor_json_pair "claude_profile" "$claude_profile_state"; printf ',\n'
  doctor_json_pair "opencode_config" "$opencode_config_state"; printf ',\n'
  doctor_json_pair "opencode_profile" "$opencode_profile_state"; printf ',\n'
  doctor_json_pair "omp_config" "$omp_config_state"; printf '\n'
  printf '  },\n'
  printf '  "suggestions": [\n'
  if [ -n "$suggestions" ]; then
    printf '%s\n' "$suggestions" | while IFS= read -r suggestion; do
      [ -n "$suggestion" ] || continue
      printf '    "%s"\n' "$(doctor_json_escape "$suggestion")"
    done | sed '$!s/$/,/'
  fi
  printf '  ]\n'
  printf '}\n'
}

print_doctor_text_summary() {
  local runtime_mode="$1"
  local requested_container_api="$2"
  local suggestions="$3"

  printf 'Agent Sandbox Doctor\n\n'

  printf 'Summary\n'
  doctor_line "project_root" "$PROJECT_ROOT"
  doctor_line "project_config" "${PROJECT_CONFIG_FILE:-none}"
  doctor_line "runtime" "$RUNTIME"
  doctor_line "runtime_mode" "$runtime_mode"
  doctor_line "container_api" "${requested_container_api} -> ${CONTAINER_API_MODE}"
  doctor_line "nix_tool_helper" "$NIX_TOOL_HELPER_MODE"
  doctor_line "dev_env_mode" "${AGENT_DEV_ENV:-host-helper}"

  printf '\nSuggested next steps\n'
  printf '%s\n' "$suggestions" | sed 's/^/- /'
}

print_doctor_text_verbose() {
  local requested_container_api="$1"
  local runtime_mode="$2"
  local tools_list="$3"
  local podman_socket_state="$4"
  local docker_socket_state="$5"
  local nix_daemon_socket_state="$6"
  local codex_config_state="$7"
  local codex_profile_state="$8"
  local claude_config_state="$9"
  local claude_profile_state="${10}"
  local opencode_config_state="${11}"
  local opencode_profile_state="${12}"
  local omp_config_state="${13}"
  local suggestions="${14}"

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
  doctor_line "podman_host_socket" "$podman_socket_state"
  doctor_line "docker_host_socket" "$docker_socket_state"
  doctor_line "nix_daemon_socket" "$nix_daemon_socket_state"

  printf '\nTool Config\n'
  doctor_line "codex_config" "$codex_config_state"
  doctor_line "codex_profile" "$codex_profile_state"
  doctor_line "claude_config" "$claude_config_state"
  doctor_line "claude_profile" "$claude_profile_state"
  doctor_line "opencode_config" "$opencode_config_state"
  doctor_line "opencode_profile" "$opencode_profile_state"
  doctor_line "omp_config" "$omp_config_state"

  printf '\nSuggested next steps\n'
  printf '%s\n' "$suggestions" | sed 's/^/- /'
}

print_doctor_suggestions() {
  local printed="0"

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
  local podman_socket_state=""
  local docker_socket_state=""
  local nix_daemon_socket_state=""
  local codex_config_state=""
  local codex_profile_state=""
  local claude_config_state=""
  local claude_profile_state=""
  local opencode_config_state=""
  local opencode_profile_state=""
  local omp_config_state=""
  local suggestions=""

  OS_NAME="${OS_NAME:-$(uname -s)}"

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
  podman_socket_state="$(doctor_path_state "$podman_socket_path")"
  docker_socket_state="$(doctor_path_state "$docker_socket_path")"
  nix_daemon_socket_state="$(doctor_path_state "$nix_daemon_socket_path")"
  codex_config_state="$(doctor_path_state "$CODEX_HOST_CONFIG")"
  codex_profile_state="$(doctor_profile_state "${CODEX_PROFILE:-}" "$CODEX_PROFILE_BASE/${CODEX_PROFILE:-}.json")"
  claude_config_state="$(doctor_path_state "$CLAUDE_HOST_CONFIG")"
  claude_profile_state="$(doctor_profile_state "${CLAUDE_PROFILE:-}" "$CLAUDE_PROFILE_BASE/${CLAUDE_PROFILE:-}.json")"
  opencode_config_state="$(doctor_path_state "$OPENCODE_HOST_CONFIG")"
  opencode_profile_state="$(doctor_profile_state "${OPENCODE_PROFILE:-}" "$OPENCODE_PROFILE_BASE/${OPENCODE_PROFILE:-}.json")"
  omp_config_state="$(doctor_path_state "$OMP_HOST_CONFIG")"
  suggestions="$(print_doctor_suggestions | sed 's/^- //')"

  if [ "$DOCTOR_OUTPUT" = "json" ]; then
    print_doctor_json \
      "$requested_container_api" \
      "$runtime_mode" \
      "$tools_list" \
      "$podman_socket_state" \
      "$docker_socket_state" \
      "$nix_daemon_socket_state" \
      "$codex_config_state" \
      "$codex_profile_state" \
      "$claude_config_state" \
      "$claude_profile_state" \
      "$opencode_config_state" \
      "$opencode_profile_state" \
      "$omp_config_state" \
      "$suggestions"
    exit 0
  fi

  if [ "$DOCTOR_VERBOSE" = "1" ]; then
    print_doctor_text_verbose \
      "$requested_container_api" \
      "$runtime_mode" \
      "$tools_list" \
      "$podman_socket_state" \
      "$docker_socket_state" \
      "$nix_daemon_socket_state" \
      "$codex_config_state" \
      "$codex_profile_state" \
      "$claude_config_state" \
      "$claude_profile_state" \
      "$opencode_config_state" \
      "$opencode_profile_state" \
      "$omp_config_state" \
      "$suggestions"
  else
    print_doctor_text_summary "$runtime_mode" "$requested_container_api" "$suggestions"
  fi

  exit 0
}
