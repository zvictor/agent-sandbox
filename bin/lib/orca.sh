# Opt-in native client for the host Orca runtime. No host command execution.
ORCA_ENABLED=0
ORCA_NODE=""
ORCA_CLI_PATH=""
ORCA_PROJECTION_DIR=""

orca_store_root() {
  case "$1" in
    /nix/store/?*)
      local relative="${1#/nix/store/}"
      printf '/nix/store/%s\n' "${relative%%/*}"
      ;;
    *) echo '[agent] Orca integration requires a Nix-store installation' >&2; return 1 ;;
  esac
}

resolve_orca_cli_path() {
  local executable="" root="" closure="" item="" candidate=""
  local -a candidates=()
  if [ -n "${AGENT_ORCA_CLI_PATH:-}" ]; then
    ORCA_CLI_PATH="$(readlink -f -- "$AGENT_ORCA_CLI_PATH")" || return 1
  else
    executable="$(command -v orca-ide)" || {
      echo '[agent] orca-ide is unavailable on the host; set AGENT_ORCA_CLI_PATH to its packaged out/cli/index.js' >&2
      return 1
    }
    executable="$(readlink -f -- "$executable")" || return 1
    root="$(orca_store_root "$executable")" || return 1
    closure="$(nix_cmd path-info --recursive "$root")" || return 1
    while IFS= read -r item; do
      candidate="$item/resources/app.asar.unpacked/out/cli/index.js"
      [ ! -f "$candidate" ] || candidates+=( "$candidate" )
    done <<< "$closure"
    if [ "${#candidates[@]}" -ne 1 ]; then
      echo '[agent] expected exactly one packaged Orca CLI in the installed closure; set AGENT_ORCA_CLI_PATH explicitly' >&2
      return 1
    fi
    ORCA_CLI_PATH="${candidates[0]}"
  fi
  case "$ORCA_CLI_PATH" in
    */resources/app.asar.unpacked/out/cli/index.js) ;;
    *) echo '[agent] AGENT_ORCA_CLI_PATH must name the packaged resources/app.asar.unpacked/out/cli/index.js' >&2; return 1 ;;
  esac
  [ -f "$ORCA_CLI_PATH" ] || {
    echo '[agent] packaged Orca CLI is missing' >&2; return 1
  }
  root="$(orca_store_root "$ORCA_CLI_PATH")" || return 1
  retain_runtime_artifact orca-cli "$root" || return 1
}

prepare_orca() {
  local tools="" profile="" status_json="" attempt=0 pid=""
  ORCA_ENABLED="${AGENT_ORCA:-0}"
  case "$ORCA_ENABLED" in
    0) return 0 ;;
    1) ;;
    *) echo '[agent] AGENT_ORCA must be 0 or 1' >&2; return 1 ;;
  esac
  if [ "$OS_NAME" != Linux ] || [ "$RUNTIME" != podman ] || remote_container_mode || firecracker_host_profile; then
    echo '[agent] Orca integration supports local Linux Podman default/rootless-linux sandboxes only' >&2
    return 1
  fi
  case "$(current_sandbox_profile)" in
    default|rootless-linux) ;;
    *) echo '[agent] unsupported Orca sandbox profile' >&2; return 1 ;;
  esac
  resolve_orca_cli_path || return 1
  tools="$(nix_cmd build --out-link "$RUNTIME_LEASE_ROOTS_DIR/orca-tools" --print-out-paths "path:$AGENT_BIN_DIR/..#orca-tools")" || return 1
  ORCA_NODE="$tools/bin/node"
  [ -x "$ORCA_NODE" ] || { echo '[agent] Orca Node runtime is missing' >&2; return 1; }
  retain_runtime_artifact orca-tools "$tools" || return 1
  # Node executes the installed CLI directly, avoiding the desktop FHS launcher.
  if ! timeout 15 "$ORCA_NODE" "$ORCA_CLI_PATH" skills get orchestration >/dev/null; then
    echo '[agent] installed Orca CLI cannot load its orchestration guide under Node; update Orca or check AGENT_ORCA_CLI_PATH' >&2
    return 1
  fi
  profile="${AGENT_ORCA_USER_DATA_PATH:-${XDG_CONFIG_HOME:-$HOST_HOME/.config}/orca}"
  profile="$(readlink -f -- "$profile")" || return 1
  "$ORCA_NODE" "$AGENT_BIN_DIR/agent-orca-runtime.cjs" inspect "$profile" >/dev/null || return 1
  status_json="$(ORCA_USER_DATA_PATH="$profile" timeout 15 "$ORCA_NODE" "$ORCA_CLI_PATH" status --json)" || {
    echo '[agent] cannot query the host Orca runtime; start Orca and retry' >&2
    return 1
  }
  if ! jq -e '.ok == true and .result.runtime.reachable == true' >/dev/null <<< "$status_json"; then
    echo '[agent] host Orca runtime is unreachable; start Orca and check AGENT_ORCA_USER_DATA_PATH' >&2
    return 1
  fi
  ORCA_PROJECTION_DIR="$RUNTIME_LEASE_DIR/orca/runtime"
  mkdir -p -m 0700 "$RUNTIME_LEASE_DIR/orca" "$ORCA_PROJECTION_DIR" || return 1
  chmod 0700 "$RUNTIME_LEASE_DIR/orca" "$ORCA_PROJECTION_DIR" || return 1
  (
    umask 077
    exec "$ORCA_NODE" "$AGENT_BIN_DIR/agent-orca-runtime.cjs" serve "$profile" "$ORCA_PROJECTION_DIR" \
      </dev/null >"$RUNTIME_LEASE_DIR/orca/service.log" 2>&1
  ) &
  pid=$!
  printf '%s\n' "$pid" > "$RUNTIME_LEASE_DIR/orca/service.pid"
  while [ "$attempt" -lt 50 ]; do
    if [ -f "$ORCA_PROJECTION_DIR/ready" ] && [ -f "$ORCA_PROJECTION_DIR/orca-runtime.json" ] && kill -0 "$pid" 2>/dev/null; then
      echo '[agent] Orca access enabled: agents can control host Orca terminals and workers' >&2
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  echo '[agent] Orca runtime connection failed to start' >&2
  sed -n '1,10p' "$RUNTIME_LEASE_DIR/orca/service.log" >&2
  return 1
}

prepare_orca_commands() {
  # Persistent path guards may have been prepared by an earlier launch.
  rm -f "$PATH_GUARD_HOST_DIR/orca-ide"
  [ "$ORCA_ENABLED" = 1 ] || return 0
  {
    printf '#!/bin/bash\nset -euo pipefail\n'
    printf 'export ORCA_USER_DATA_PATH=/run/agent-orca\n'
    printf 'exec %q %q "$@"\n' "$ORCA_NODE" "$ORCA_CLI_PATH"
  } > "$PATH_GUARD_HOST_DIR/orca-ide"
  chmod 0755 "$PATH_GUARD_HOST_DIR/orca-ide"
}

append_orca_container_args() {
  [ "$ORCA_ENABLED" = 1 ] || return 0
  ARGS+=( -v "$ORCA_PROJECTION_DIR:/run/agent-orca:ro" )
  ARGS+=( -e ORCA_USER_DATA_PATH=/run/agent-orca )
  ARGS+=( -e ORCA_CLI_COMMAND=/run/agent-path-guard/orca-ide )
}
