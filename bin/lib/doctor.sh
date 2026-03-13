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

doctor_auth_state() {
  local selector_value="$1"
  local auth_base_dir="$2"
  local legacy_profile_name="$3"
  local legacy_profile_base_dir="$4"
  local resolved_path=""

  resolved_path="$(resolve_auth_file_path "$selector_value" "$auth_base_dir" "$legacy_profile_name" "$legacy_profile_base_dir")"

  if [ -n "$selector_value" ]; then
    if [ -f "$resolved_path" ]; then
      printf '%s (%s)\n' "$selector_value" "$resolved_path"
    else
      printf '%s (missing: %s)\n' "$selector_value" "$resolved_path"
    fi
    return 0
  fi

  if [ -n "$legacy_profile_name" ]; then
    if [ -f "$resolved_path" ]; then
      printf 'legacy:%s (%s)\n' "$legacy_profile_name" "$resolved_path"
    else
      printf 'legacy:%s (missing: %s)\n' "$legacy_profile_name" "$resolved_path"
    fi
    return 0
  fi

  if [ -d "$auth_base_dir" ]; then
    printf 'unset (managed slots: %s)\n' "$auth_base_dir"
  else
    printf 'unset\n'
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
  local tools_source="$4"
  local podman_socket_state="$5"
  local docker_socket_state="$6"
  local nix_daemon_socket_state="$7"
  local codex_config_state="$8"
  local codex_auth_state="$9"
  local claude_config_state="${10}"
  local claude_auth_state="${11}"
  local opencode_config_state="${12}"
  local opencode_auth_state="${13}"
  local omp_config_state="${14}"
  local suggestions="${15}"

  printf '{\n'
  printf '  "project": {\n'
  doctor_json_pair "root" "$PROJECT_ROOT"; printf ',\n'
  doctor_json_pair "root_source" "$PROJECT_ROOT_SOURCE"; printf ',\n'
  doctor_json_pair "nix_dir" "$PROJECT_NIX_DIR"; printf ',\n'
  doctor_json_pair "config_file" "${PROJECT_CONFIG_FILE:-none}"; printf ',\n'
  doctor_json_pair "contract" "$(doctor_contract_source)"; printf ',\n'
  doctor_json_pair "sandbox_flake" "$SANDBOX_FLAKE"; printf '\n'
  printf '  },\n'
  printf '  "runtime": {\n'
  doctor_json_pair "runtime" "$RUNTIME"; printf ',\n'
  doctor_json_pair "mode" "$runtime_mode"; printf ',\n'
  doctor_json_pair "tools_enabled" "$tools_list"; printf ',\n'
  doctor_json_pair "tools_source" "$tools_source"; printf '\n'
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
  doctor_json_pair "codex_auth" "$codex_auth_state"; printf ',\n'
  doctor_json_pair "claude_config" "$claude_config_state"; printf ',\n'
  doctor_json_pair "claude_auth" "$claude_auth_state"; printf ',\n'
  doctor_json_pair "opencode_config" "$opencode_config_state"; printf ',\n'
  doctor_json_pair "opencode_auth" "$opencode_auth_state"; printf ',\n'
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
  local tools_list="$3"
  local suggestions="$4"

  printf 'Agent Sandbox Doctor\n\n'

  printf 'Summary\n'
  doctor_line "project_root" "$PROJECT_ROOT"
  doctor_line "project_root_source" "$PROJECT_ROOT_SOURCE"
  doctor_line "project_config" "${PROJECT_CONFIG_FILE:-none}"
  doctor_line "runtime" "$RUNTIME"
  doctor_line "runtime_mode" "$runtime_mode"
  doctor_line "container_api" "${requested_container_api} -> ${CONTAINER_API_MODE}"
  doctor_line "tools_enabled" "$tools_list"
  doctor_line "nix_tool_helper" "$NIX_TOOL_HELPER_MODE"
  doctor_line "dev_env_mode" "${AGENT_DEV_ENV:-host-helper}"

  printf '\nSuggested next steps\n'
  printf '%s\n' "$suggestions" | sed 's/^/- /'
}

print_doctor_text_verbose() {
  local requested_container_api="$1"
  local runtime_mode="$2"
  local tools_list="$3"
  local tools_source="$4"
  local podman_socket_state="$5"
  local docker_socket_state="$6"
  local nix_daemon_socket_state="$7"
  local codex_config_state="$8"
  local codex_auth_state="$9"
  local claude_config_state="${10}"
  local claude_auth_state="${11}"
  local opencode_config_state="${12}"
  local opencode_auth_state="${13}"
  local omp_config_state="${14}"
  local suggestions="${15}"

  printf 'Agent Sandbox Doctor\n\n'

  printf 'Project\n'
  doctor_line "project_root" "$PROJECT_ROOT"
  doctor_line "project_root_source" "$PROJECT_ROOT_SOURCE"
  doctor_line "project_nix_dir" "$PROJECT_NIX_DIR"
  doctor_line "project_config" "${PROJECT_CONFIG_FILE:-none}"
  doctor_line "project_contract" "$(doctor_contract_source)"
  doctor_line "sandbox_flake" "$SANDBOX_FLAKE"

  printf '\nRuntime\n'
  doctor_line "runtime" "$RUNTIME"
  doctor_line "runtime_mode" "$runtime_mode"
  doctor_line "tools_enabled" "$tools_list"
  doctor_line "tools_source" "$tools_source"

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
  doctor_line "codex_auth" "$codex_auth_state"
  doctor_line "claude_config" "$claude_config_state"
  doctor_line "claude_auth" "$claude_auth_state"
  doctor_line "opencode_config" "$opencode_config_state"
  doctor_line "opencode_auth" "$opencode_auth_state"
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

  if [ "${PROJECT_ROOT_SOURCE:-}" = "git" ] && [ -z "${AGENT_PROJECT_ROOT:-}" ] && [ "$(pwd -P)" != "$PROJECT_ROOT" ]; then
    doctor_note "Project root came from the enclosing git repository ($PROJECT_ROOT). Set AGENT_PROJECT_ROOT if you meant to sandbox only the current subdirectory."
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

  if [ "${EFFECTIVE_TOOLS_SOURCE:-}" = "fallback-all" ]; then
    doctor_note "No host agent config roots were detected, so all supported tools remain enabled. Set AGENT_TOOLS if you want a narrower project allowlist."
    printed="1"
  fi

  if [ -n "${CODEX_AUTH:-}" ] && [ ! -f "$(resolve_auth_file_path "$CODEX_AUTH" "$CODEX_AUTH_BASE" "" "")" ]; then
    if printf '%s\n' "$CODEX_AUTH" | grep -Eq '^(/|\./|\.\./|~|~/)'; then
      doctor_note "Fix CODEX_AUTH=$CODEX_AUTH so it points to a readable credentials file, or unset it to use the default host Codex auth."
    else
      doctor_note "Create the named Codex login with 'agent login codex $CODEX_AUTH --use', or set CODEX_AUTH to a readable credential file path."
    fi
    printed="1"
  fi

  if [ -n "${CLAUDE_AUTH:-}" ] && [ ! -f "$(resolve_auth_file_path "$CLAUDE_AUTH" "$CLAUDE_AUTH_BASE" "" "")" ]; then
    doctor_note "Fix CLAUDE_AUTH=$CLAUDE_AUTH so it points to a readable credential file or named managed slot."
    printed="1"
  fi

  if [ -n "${OPENCODE_AUTH:-}" ] && [ ! -f "$(resolve_auth_file_path "$OPENCODE_AUTH" "$OPENCODE_AUTH_BASE" "" "")" ]; then
    doctor_note "Fix OPENCODE_AUTH=$OPENCODE_AUTH so it points to a readable credential file or named managed slot."
    printed="1"
  fi

  if [ -n "${CODEX_PROFILE:-}" ] && [ -z "${CODEX_AUTH:-}" ]; then
    doctor_note "CODEX_PROFILE is a legacy compatibility alias. Prefer CODEX_AUTH=<name-or-path> for new setups."
    printed="1"
  fi

  if [ -n "${CLAUDE_PROFILE:-}" ] && [ -z "${CLAUDE_AUTH:-}" ]; then
    doctor_note "CLAUDE_PROFILE is a legacy compatibility alias. Prefer CLAUDE_AUTH=<name-or-path> for new setups."
    printed="1"
  fi

  if [ -n "${OPENCODE_PROFILE:-}" ] && [ -z "${OPENCODE_AUTH:-}" ]; then
    doctor_note "OPENCODE_PROFILE is a legacy compatibility alias. Prefer OPENCODE_AUTH=<name-or-path> for new setups."
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
  local codex_auth_state=""
  local claude_config_state=""
  local claude_auth_state=""
  local opencode_config_state=""
  local opencode_auth_state=""
  local omp_config_state=""
  local suggestions=""
  local tools_source=""

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

  resolve_effective_tools_list
  tools_list="${EFFECTIVE_TOOLS_LIST:-$KNOWN_TOOLS}"
  tools_source="${EFFECTIVE_TOOLS_SOURCE:-fallback-all}"
  runtime_mode="$(doctor_runtime_mode)"
  runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  podman_socket_path="$runtime_dir/podman/podman.sock"
  podman_socket_state="$(doctor_path_state "$podman_socket_path")"
  docker_socket_state="$(doctor_path_state "$docker_socket_path")"
  nix_daemon_socket_state="$(doctor_path_state "$nix_daemon_socket_path")"
  codex_config_state="$(doctor_path_state "$CODEX_HOST_CONFIG")"
  codex_auth_state="$(doctor_auth_state "${CODEX_AUTH:-}" "$CODEX_AUTH_BASE" "${CODEX_PROFILE:-}" "$CODEX_PROFILE_BASE")"
  claude_config_state="$(doctor_path_state "$CLAUDE_HOST_CONFIG")"
  claude_auth_state="$(doctor_auth_state "${CLAUDE_AUTH:-}" "$CLAUDE_AUTH_BASE" "${CLAUDE_PROFILE:-}" "$CLAUDE_PROFILE_BASE")"
  opencode_config_state="$(doctor_path_state "$OPENCODE_HOST_CONFIG")"
  opencode_auth_state="$(doctor_auth_state "${OPENCODE_AUTH:-}" "$OPENCODE_AUTH_BASE" "${OPENCODE_PROFILE:-}" "$OPENCODE_PROFILE_BASE")"
  omp_config_state="$(doctor_path_state "$OMP_HOST_CONFIG")"
  suggestions="$(print_doctor_suggestions | sed 's/^- //')"

  if [ "$DOCTOR_OUTPUT" = "json" ]; then
    print_doctor_json \
      "$requested_container_api" \
      "$runtime_mode" \
      "$tools_list" \
      "$tools_source" \
      "$podman_socket_state" \
      "$docker_socket_state" \
      "$nix_daemon_socket_state" \
      "$codex_config_state" \
      "$codex_auth_state" \
      "$claude_config_state" \
      "$claude_auth_state" \
      "$opencode_config_state" \
      "$opencode_auth_state" \
      "$omp_config_state" \
      "$suggestions"
    exit 0
  fi

  if [ "$DOCTOR_VERBOSE" = "1" ]; then
    print_doctor_text_verbose \
      "$requested_container_api" \
      "$runtime_mode" \
      "$tools_list" \
      "$tools_source" \
      "$podman_socket_state" \
      "$docker_socket_state" \
      "$nix_daemon_socket_state" \
      "$codex_config_state" \
      "$codex_auth_state" \
      "$claude_config_state" \
      "$claude_auth_state" \
      "$opencode_config_state" \
      "$opencode_auth_state" \
      "$omp_config_state" \
      "$suggestions"
  else
    print_doctor_text_summary "$runtime_mode" "$requested_container_api" "$tools_list" "$suggestions"
  fi

  exit 0
}
