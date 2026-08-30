#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

fail() {
  echo "[fail] $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  case "$haystack" in
    *"$needle"*) ;;
    *)
      fail "expected output to contain: $needle"
      ;;
  esac
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"

  case "$haystack" in
    *"$needle"*)
      fail "expected output not to contain: $needle"
      ;;
    *)
      ;;
  esac
}

write_need_materialization_cache() {
  local need_cache="$1"
  local installable="$2"
  local out_path="$3"
  local bin_path="$4"
  local lease_id="$5"
  local receipts_dir="$6"
  local cache_key cache_file receipt_path

  cache_key="$(printf '%s' "$installable" | sha256sum | awk '{print $1}')"
  cache_file="$need_cache/materialized/$cache_key.env"
  receipt_path="$receipts_dir/need-test.json"
  mkdir -p "$(dirname "$cache_file")" "$receipts_dir"
  jq -n \
    --arg lease_id "$lease_id" \
    --arg installable "$installable" \
    --arg out_path "$out_path" \
    --arg bin_path "$bin_path" \
    '{
      schema_version: 1,
      lease_id: $lease_id,
      kind: "need-materialization",
      installable: $installable,
      output_paths: [$out_path],
      selected_out_path: $out_path,
      bin_path: (if $bin_path == "" then null else $bin_path end),
      closure: []
    }' > "$receipt_path"
  {
    printf 'status=ok\n'
    printf 'installable=%s\n' "$installable"
    printf 'out_path=%s\n' "$out_path"
    printf 'bin_path=%s\n' "$bin_path"
    printf 'lease_id=%s\n' "$lease_id"
    printf 'receipt_path=%s\n' "$receipt_path"
  } > "$cache_file"
}

pin_shell_fetchtarball_for() (
  set -euo pipefail

  local url="$1"
  local locked_hash="$2"
  local fresh_hash="$3"
  local tmp_dir target_dir bin_dir cache_dir project_root project_key url_key lock_file output calls

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  target_dir="$tmp_dir/project"
  bin_dir="$tmp_dir/bin"
  cache_dir="$tmp_dir/cache"
  project_root="$tmp_dir/source-project"
  mkdir -p "$target_dir" "$bin_dir" "$cache_dir" "$project_root"

  printf '{ pkgs ? import (fetchTarball "%s") {} }: pkgs.mkShell { packages = []; }\n' "$url" > "$target_dir/shell.nix"

  project_key="$(printf '%s' "$project_root" | sha256sum | awk '{print $1}')"
  url_key="$(printf '%s' "$url" | sha256sum | awk '{print $1}')"
  lock_file="$cache_dir/project-contracts/$project_key/pinned-nixpkgs-$url_key.json"
  if [ -n "$locked_hash" ]; then
    mkdir -p "$(dirname "$lock_file")"
    printf '{"url":"%s","sha256":"%s"}\n' "$url" "$locked_hash" > "$lock_file"
  fi

  cat > "$bin_dir/nix-prefetch-url" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'called %s\n' "\$*" >> "$tmp_dir/prefetch.log"
printf '%s\n' "$fresh_hash"
EOF
  chmod +x "$bin_dir/nix-prefetch-url"

  source "$REPO_ROOT/bin/lib/project_contract.sh"
  output="$(CACHE_DIR="$cache_dir" PROJECT_ROOT="$project_root" PATH="$bin_dir:/usr/bin:/bin" pin_shell_fetchtarball "$target_dir" 2>&1)"

  if [ -f "$tmp_dir/prefetch.log" ]; then
    calls="$(wc -l < "$tmp_dir/prefetch.log")"
    printf 'prefetch=%s\n' "$(cat "$tmp_dir/prefetch.log")"
  else
    calls="0"
  fi

  printf 'output=%s\n' "$output"
  printf 'pinned=%s\n' "$(cat "$target_dir/.agent-sandbox-pinned-nixpkgs.json")"
  printf 'calls=%s\n' "$calls"
  printf 'lock_path=%s\n' "$lock_file"
  if [ -f "$lock_file" ]; then
    printf 'lock=%s\n' "$(cat "$lock_file")"
  fi
)

stage_symlinked_shell_contract() (
  set -euo pipefail

  local tmp_dir project_dir target_dir

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  project_dir="$tmp_dir/project"
  target_dir="$tmp_dir/staged"
  mkdir -p "$project_dir/main/nix" "$target_dir"

  ln -s main/shell.nix "$project_dir/shell.nix"
  printf '{ pkgs ? import <nixpkgs> {} }: import ./nix/default.nix { inherit pkgs; }\n' > "$project_dir/main/shell.nix"
  printf '{ pkgs }: []\n' > "$project_dir/main/nix/default.nix"
  printf 'font template\n' > "$project_dir/main/nix/fonts.conf.in"

  source "$REPO_ROOT/bin/lib/project_contract.sh"

  PROJECT_ROOT="$project_dir"
  PROJECT_NIX_DIR="$project_dir/nix"
  unset AGENT_PROJECT_NIX_DIR
  unset AGENT_PROJECT_CONTRACT_FILES

  stage_project_contract_input "$target_dir"

  if [ -L "$target_dir/shell.nix" ]; then
    printf 'shell_is_symlink=1\n'
  else
    printf 'shell_is_symlink=0\n'
  fi
  printf 'shell=%s\n' "$(cat "$target_dir/shell.nix")"
  printf 'default=%s\n' "$(cat "$target_dir/nix/default.nix")"
  printf 'template=%s\n' "$(cat "$target_dir/nix/fonts.conf.in")"
)

workspace_mount_args_for() (
  set -euo pipefail

  local workspace_path="$1"
  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  WORKSPACE_PATH="$workspace_path"
  Z_SUFFIX=""
  ARGS=()
  append_workspace_mount_args

  printf '%s\n' "${ARGS[@]}"
)

passthrough_env_args_for() (
  set -euo pipefail

  split_csv_or_lines() {
    local value="$1"
    printf '%s\n' "$value" | tr ',' '\n' | sed '/^[[:space:]]*$/d'
  }

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  ARGS=()
  append_passthrough_env_args

  printf '%s\n' "${ARGS[@]}"
)

ssh_agent_args_for() (
  set -euo pipefail

  local socket_path="$1"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  resolve_ssh_auth_socket() {
    printf '%s\n' "$socket_path"
  }

  Z_SUFFIX=""
  ARGS=()
  append_ssh_agent_args

  printf '%s\n' "${ARGS[@]}"
)

prepare_ssh_runtime_for() (
  set -euo pipefail

  local host_home="$1"
  local tool_cache_dir="$2"
  local resolved_sock="${3:-}"
  local tool_name="${4:-}"
  local workspace_path="${5:-}"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  HOST_HOME="$host_home"
  TOOL_CACHE_DIR="$tool_cache_dir"
  TOOL="$tool_name"
  WORKSPACE_PATH="$workspace_path"

  resolve_ssh_auth_socket() {
    printf '%s\n' "$resolved_sock"
  }

  prepare_ssh_runtime_dir

  if [ -n "${SSH_RUNTIME_DIR:-}" ]; then
    printf '%s\n' "$SSH_RUNTIME_DIR"
  fi
)

ssh_runtime_mount_args_for() (
  set -euo pipefail

  local runtime_dir="$1"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  prepare_ssh_runtime_dir() {
    SSH_RUNTIME_DIR="$runtime_dir"
  }

  Z_SUFFIX=""
  ARGS=()
  append_ssh_runtime_mount_args

  printf '%s\n' "${ARGS[@]}"
)

codex_ssh_sandbox_args_for() (
  set -euo pipefail

  local runtime_dir="$1"
  local resolved_sock="$2"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  TOOL="codex"
  SSH_RUNTIME_DIR="$runtime_dir"

  resolve_ssh_auth_socket() {
    printf '%s\n' "$resolved_sock"
  }

  Z_SUFFIX=""
  ARGS=()
  append_codex_ssh_sandbox_args

  printf '%s\n' "${ARGS[@]}"
)

dev_env_args_for() (
  set -euo pipefail

  local workspace_path="$1"
  local project_root="$2"
  local env_file="$3"
  local allow_sudo="${4:-0}"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  PATH_GUARD_CONTAINER_DIR="/run/agent-path-guard"
  SUDO_RUNTIME_PATH=""
  if [ "$allow_sudo" = "1" ]; then
    SUDO_RUNTIME_PATH="/agent-sudo/bin"
  fi
  WORKSPACE_NODE_MODULES_BIN="$workspace_path/node_modules/.bin"
  NEED_CACHE_PATH="/cache/need"
  NEED_TOOLS_PATH="$NEED_CACHE_PATH/projects/$(runtime_path_scope_key "$project_root")/bin"
  IMAGE_FALLBACK_PATH="/bin:/usr/bin:/usr/local/bin"
  DEV_ENV_ENV_FILE="$env_file"

  ARGS=()
  append_dev_env_args

  printf '%s\n' "${ARGS[@]}"
)

runtime_path_for() (
  set -euo pipefail

  local workspace_path="$1"
  local project_root="$2"
  local dev_env_path="${3:-}"
  local allow_sudo="${4:-0}"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  PATH_GUARD_CONTAINER_DIR="/run/agent-path-guard"
  SUDO_RUNTIME_PATH=""
  if [ "$allow_sudo" = "1" ]; then
    SUDO_RUNTIME_PATH="/agent-sudo/bin"
  fi
  WORKSPACE_NODE_MODULES_BIN="$workspace_path/node_modules/.bin"
  NEED_CACHE_PATH="/cache/need"
  NEED_TOOLS_PATH="$NEED_CACHE_PATH/projects/$(runtime_path_scope_key "$project_root")/bin"
  IMAGE_FALLBACK_PATH="/bin:/usr/bin:/usr/local/bin"

  compose_runtime_path "$dev_env_path"
)

runtime_mode_for() (
  set -euo pipefail

  local runtime="$1"
  local container_host="${2:-}"
  local profile="${3:-default}"

  source "$REPO_ROOT/bin/lib/artifact_prep.sh"

  SANDBOX_PROFILE="$profile"
  AGENT_SANDBOX_PROFILE="$profile"
  RUNTIME="$runtime"
  OS_NAME="Linux"
  if [ -n "$container_host" ]; then
    CONTAINER_HOST="$container_host"
  else
    unset CONTAINER_HOST
  fi

  resolve_runtime_mode

  printf '%s\n' "$MODE"
)

stream_image_helper_invocation_for() (
  set -euo pipefail

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  source "$REPO_ROOT/bin/lib/artifact_prep.sh"

  nix_cmd() {
    printf 'TMPDIR=%s\n' "${TMPDIR:-}"
    printf 'argv=%s\n' "$*"
  }

  SANDBOX_FLAKE="path:/sandbox"
  PROJECT_OVERRIDE_ARGS=(--override-input projectPkgs path:/project-store)
  LOCK_ARGS=(--no-update-lock-file)
  CACHE_DIR="$tmp_dir/cache"

  run_stream_image_helper copyToDockerDaemon --probe flag
)

path_guard_entries_for() (
  set -euo pipefail

  local profile="${1:-default}"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  SANDBOX_PROFILE="$profile"
  AGENT_SANDBOX_PROFILE="$profile"
  HELPER_TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$HELPER_TMPDIR" "$PATH_GUARD_HOST_DIR"' EXIT

  prepare_path_guard_dir

  find "$PATH_GUARD_HOST_DIR" -maxdepth 1 -type l -printf '%f -> %l\n' | LC_ALL=C sort
)

base_container_args_for() (
  set -euo pipefail

  local allow_sudo="${1:-0}"
  local profile="${2:-default}"
  local runtime="${3:-podman}"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  SANDBOX_PROFILE="$profile"
  AGENT_SANDBOX_PROFILE="$profile"
  if [ "$allow_sudo" = "1" ]; then
    export AGENT_ALLOW_SUDO=1
  else
    unset AGENT_ALLOW_SUDO
  fi

  TOOL="codex"
  RUNTIME="$runtime"
  WORKSPACE_PATH="/workspace"
  WORKSPACE_RUNTIME_PATH="/cache/need/bin:/bin:/usr/bin:/usr/local/bin"
  TOOL_CACHE_DIR="/cache/tools/codex"
  NEED_TOOLS_PATH="/cache/need/projects/project/bin"
  NIX_CONFIG="sandbox = false"
  Z_SUFFIX=""
  ARGS=()

  build_base_container_args

  printf '%s\n' "${ARGS[@]}"
)

remote_base_container_args_for() (
  set -euo pipefail

  local profile="${1:-default}"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  SANDBOX_PROFILE="$profile"
  AGENT_SANDBOX_PROFILE="$profile"
  AGENT_REMOTE_CONTAINER_MODE=1
  AGENT_REMOTE_POD_NAME="agent-remote-test"
  AGENT_REMOTE_RUNTIME_CONTAINER="agent-remote-test-runtime"
  if [ "$profile" = "firecracker-host" ]; then
    AGENT_REMOTE_POD_DISABLED=1
  fi

  TOOL="codex"
  WORKSPACE_PATH="/workspace"
  WORKSPACE_RUNTIME_PATH="/cache/need/bin:/bin:/usr/bin:/usr/local/bin"
  TOOL_CACHE_DIR="/cache/tools/codex"
  NEED_TOOLS_PATH="/cache/need/projects/project/bin"
  NIX_CONFIG="sandbox = false"
  Z_SUFFIX=""
  ARGS=()

  build_base_container_args

  printf '%s\n' "${ARGS[@]}"
)

runtime_identity_args_for() (
  set -euo pipefail

  local tmp_dir allow_sudo profile
  allow_sudo="${1:-0}"
  profile="${2:-default}"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  mkdir -p "$tmp_dir/rootfs/agent-sudo/bin" "$tmp_dir/helper"
  printf '#!/bin/sh\n' > "$tmp_dir/rootfs/agent-sudo/bin/sudo"
  chmod 0755 "$tmp_dir/rootfs/agent-sudo/bin/sudo"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  SANDBOX_PROFILE="$profile"
  AGENT_SANDBOX_PROFILE="$profile"
  if [ "$allow_sudo" = "1" ]; then
    export AGENT_ALLOW_SUDO=1
  else
    unset AGENT_ALLOW_SUDO
  fi

  podman() {
    if [ "${1:-}" = "unshare" ]; then
      shift
      printf 'podman_unshare=%s\n' "$*" >> "$tmp_dir/podman.log"
      if [ "${1:-}" = "chmod" ]; then
        shift
        command chmod "$@"
        return
      fi
      return 0
    fi
    return 1
  }

  sudo() {
    printf 'sudo=%s\n' "$*" >> "$tmp_dir/sudo.log"
    if [ "${1:-}" = "-n" ]; then
      shift
    fi
    case "${1:-}" in
      chown)
        return 0
        ;;
      chmod)
        shift
        command chmod "$@"
        return
        ;;
      *)
        return 0
        ;;
    esac
  }

  MODE="podman-rootfs"
  RUNTIME="podman"
  ROOTFS_OUT="$tmp_dir/rootfs"
  HELPER_TMPDIR="$tmp_dir/helper"
  Z_SUFFIX=""
  USER="agenttest"
  LOGNAME="agenttest"
  ARGS=()

  append_runtime_identity_mount_args

  printf 'args:\n'
  printf '%s\n' "${ARGS[@]}"
  printf 'passwd:\n%s\n' "$(cat "$RUNTIME_IDENTITY_HOST_DIR/passwd")"
  printf 'group:\n%s\n' "$(cat "$RUNTIME_IDENTITY_HOST_DIR/group")"
  if [ -f "$RUNTIME_IDENTITY_HOST_DIR/sudoers" ]; then
    printf 'sudoers:\n%s\n' "$(cat "$RUNTIME_IDENTITY_HOST_DIR/sudoers")"
  fi
  if [ -e "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo/bin/sudo" ]; then
    printf 'sudo_mode=%s\n' "$(stat -c '%a' "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo/bin/sudo")"
    printf 'sudoedit_mode=%s\n' "$(stat -c '%a' "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo/bin/sudoedit")"
  fi
  if [ -d "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo-disabled" ]; then
    printf 'sudo_disabled_mask=1\n'
  fi
  if [ -f "$tmp_dir/podman.log" ]; then
    cat "$tmp_dir/podman.log"
  fi
  if [ -f "$tmp_dir/sudo.log" ]; then
    cat "$tmp_dir/sudo.log"
  fi
)

runtime_identity_run_args_for() (
  set -euo pipefail

  local profile="${1:-default}"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  SANDBOX_PROFILE="$profile"
  AGENT_SANDBOX_PROFILE="$profile"
  RUNTIME="podman"
  OS_NAME="Linux"
  ARGS=()

  append_runtime_identity_args

  printf '%s\n' "${ARGS[@]}"
)

firecracker_host_args_for() (
  set -euo pipefail

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  SANDBOX_PROFILE="firecracker-host"
  AGENT_SANDBOX_PROFILE="firecracker-host"
  ARGS=()

  append_firecracker_host_args

  printf '%s\n' "${ARGS[@]}"
)

firecracker_preflight_for() (
  set -euo pipefail

  local fail_case="${1:-none}"
  local tmp_dir workspace
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  workspace="$tmp_dir/workspace"
  mkdir -p "$workspace"

  source "$REPO_ROOT/bin/lib/environment.sh"

  sudo() {
    if [ "${1:-}" = "-n" ]; then
      shift
    fi

    case "$*" in
      true)
        return 0
        ;;
      "podman info")
        return 0
        ;;
      "podman info --format {{.Host.Security.Rootless}}")
        if [ "$fail_case" = "rootless" ]; then
          printf 'true\n'
        else
          printf 'false\n'
        fi
        return 0
        ;;
      sh\ -c*)
        case "$*" in
          *"/dev/kvm"*)
            [ "$fail_case" != "kvm" ]
            return
            ;;
          *"/dev/net/tun"*)
            [ "$fail_case" != "tun" ]
            return
            ;;
          *cgroup.controllers*)
            [ "$fail_case" != "cgroup" ]
            return
            ;;
          *cgroup.freeze*)
            [ "$fail_case" != "cgroup-control" ]
            return
            ;;
          *agent-sandbox-root-write-test*)
            [ "$fail_case" != "workspace" ]
            return
            ;;
          *)
            return 0
            ;;
        esac
        ;;
    esac

    return 0
  }

  podman() {
    return 0
  }

  id() {
    if [ "$fail_case" = "sudo-launcher" ] && [ "${1:-}" = "-u" ]; then
      printf '0\n'
      return 0
    fi

    command id "$@"
  }

  OS_NAME="Linux"
  SANDBOX_PROFILE="firecracker-host"
  AGENT_SANDBOX_PROFILE="firecracker-host"
  AGENT_WORKSPACE_PATH="$workspace"
  if [ "$fail_case" = "sudo-launcher" ]; then
    SUDO_USER="agentuser"
  else
    unset SUDO_USER
  fi

  preflight_firecracker_host_profile
  printf 'preflight-ok\n'
)

rootless_linux_preflight_for() (
  set -euo pipefail

  local fail_case="${1:-none}"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  source "$REPO_ROOT/bin/lib/environment.sh"

  systemctl() {
    [ "$fail_case" != "user-manager" ]
  }

  systemd-run() {
    if [ "$fail_case" = "delegation" ]; then
      printf 'mock delegated controller failure\n' >&2
      return 1
    fi
    return 0
  }

  unshare() {
    [ "$fail_case" != "userns" ]
  }

  podman() {
    case "$*" in
      info)
        return 0
        ;;
      "info --format {{.Host.Security.Rootless}}")
        if [ "$fail_case" = "rootful" ]; then
          printf 'false\n'
        else
          printf 'true\n'
        fi
        return 0
        ;;
    esac
    return 0
  }

  id() {
    if [ "$fail_case" = "root" ] && [ "${1:-}" = "-u" ]; then
      printf '0\n'
      return 0
    fi
    command id "$@"
  }

  OS_NAME="Linux"
  SANDBOX_PROFILE="rootless-linux"
  AGENT_SANDBOX_PROFILE="rootless-linux"
  AGENT_ALLOW_SUDO=0
  XDG_RUNTIME_DIR="$tmp_dir"

  preflight_rootless_linux_profile
  printf 'preflight-ok\n'
)

stdio_target_args_for() (
  set -euo pipefail

  local profile="${1:-default}"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  SANDBOX_PROFILE="$profile"
  AGENT_SANDBOX_PROFILE="$profile"
  MODE="podman-rootfs"
  TOOL="codex"
  ROOTFS_IMAGE_ARG="/tmp/rootfs:O"
  IMAGE_ID="sha256:unused"
  SSH_RUNTIME_DIR=""
  REMAINING_ARGS=(--probe)
  ARGS=()

  append_stdio_and_target_args

  printf '%s\n' "${ARGS[@]}"
)

rootless_runtime_command_for() (
  set -euo pipefail

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  run_with_logical_argv0() {
    printf 'logical-argv0=%s\n' "$1"
    shift
    printf '%s\n' "$@"
  }

  SANDBOX_PROFILE="rootless-linux"
  AGENT_SANDBOX_PROFILE="rootless-linux"
  RUNTIME="podman"
  TOOL="codex"
  ARGS=(--probe)

  run_container_runtime
)

remote_target_args_for() (
  set -euo pipefail

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  AGENT_REMOTE_CONTAINER_MODE=1
  AGENT_REMOTE_NAME="test"
  MODE="podman-rootfs"
  TOOL="codex"
  WORKSPACE_PATH="/workspace"
  ROOTFS_IMAGE_ARG="/tmp/rootfs:O"
  IMAGE_ID="sha256:unused"
  ARGS=()

  append_stdio_and_target_args

  printf '%s\n' "${ARGS[@]}"
)

container_api_stale_pid_cleanup_for() (
  set -euo pipefail

  local tmp_dir stale_pid
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  source "$REPO_ROOT/bin/lib/container_api.sh"

  CONTAINER_API_PID_FILE="$tmp_dir/service.pid"
  CONTAINER_API_SOCKET_PATH="$tmp_dir/podman.sock"
  printf '%s\n' "$$" > "$CONTAINER_API_PID_FILE"
  : > "$CONTAINER_API_SOCKET_PATH"

  kill() {
    if [ "${1:-}" = "-0" ]; then
      command kill "$@"
      return $?
    fi

    printf 'kill_call=%s\n' "$*" >> "$tmp_dir/kill.log"
    return 0
  }

  stale_pid="$(container_api_read_service_pid)"
  printf 'stale_pid=%s\n' "$stale_pid"

  if container_api_service_running; then
    printf 'running=1\n'
  else
    printf 'running=0\n'
  fi

  container_api_discard_cached_service "$stale_pid"

  if [ -f "$CONTAINER_API_PID_FILE" ]; then
    printf 'pid_exists=1\n'
  else
    printf 'pid_exists=0\n'
  fi

  if [ -e "$CONTAINER_API_SOCKET_PATH" ]; then
    printf 'socket_exists=1\n'
  else
    printf 'socket_exists=0\n'
  fi

  if [ -f "$tmp_dir/kill.log" ]; then
    cat "$tmp_dir/kill.log"
  else
    printf 'kill_log=empty\n'
  fi
)

logical_runtime_argv0_for() (
  set -euo pipefail

  local tool_name="$1"
  local runtime_path="$2"
  local ready_file="$3"
  local stop_file="$4"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  TOOL="$tool_name"
  RUNTIME="$runtime_path"
  ARGS=(alpha beta)

  AGENT_RUNTIME_READY_FILE="$ready_file" AGENT_RUNTIME_STOP_FILE="$stop_file" run_container_runtime
)

test_opencode_wrapper_default() (
  set -euo pipefail

  local tmp_dir output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  mkdir -p "$tmp_dir/bin" "$tmp_dir/scripts"
  cp "$REPO_ROOT/scripts/opencode" "$tmp_dir/scripts/opencode"
  chmod +x "$tmp_dir/scripts/opencode"

  cat > "$tmp_dir/bin/agent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'permission=%s\n' "${OPENCODE_PERMISSION:-}"
printf 'argv=%s\n' "$*"
EOF
  chmod +x "$tmp_dir/bin/agent"

  output="$(env -i PATH="/usr/bin:/bin" "$tmp_dir/scripts/opencode" alpha beta)"
  assert_contains "$output" "permission=allow"
  assert_contains "$output" "argv=opencode alpha beta"

  output="$(env -i PATH="/usr/bin:/bin" OPENCODE_PERMISSION=ask "$tmp_dir/scripts/opencode" alpha)"
  assert_contains "$output" "permission=ask"
  assert_contains "$output" "argv=opencode alpha"
)

test_runtime_resolution_parity() (
  set -euo pipefail

  local bad_runtime doctor_output run_output status=0
  bad_runtime="definitely-not-a-runtime"

  doctor_output="$(
    cd "$REPO_ROOT" &&
      AGENT_SANDBOX_PROFILE=default AGENT_RUNTIME="$bad_runtime" ./scripts/agent doctor 2>&1
  )"
  assert_contains "$doctor_output" "requested runtime '$bad_runtime' is not available"

  set +e
  run_output="$(
    cd "$REPO_ROOT" &&
      AGENT_SANDBOX_PROFILE=default AGENT_RUNTIME="$bad_runtime" ./scripts/agent codex 2>&1
  )"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected agent run with an unavailable runtime to fail"
  assert_contains "$run_output" "[agent] requested runtime '$bad_runtime' is not available"
)

test_runtime_invocation_exposes_logical_agent_argv0() (
  set -euo pipefail

  process_parent_pid() {
    local process_id="$1"
    awk '{print $4}' "/proc/$process_id/stat" 2>/dev/null || true
  }

  process_is_descendant_of() {
    local root_pid="$1"
    local process_id="$2"
    local parent_pid=""

    while [ -n "$process_id" ] && [ "$process_id" != "1" ]; do
      parent_pid="$(process_parent_pid "$process_id")"
      [ -n "$parent_pid" ] || return 1
      [ "$parent_pid" = "$root_pid" ] && return 0
      process_id="$parent_pid"
    done

    return 1
  }

  local tmp_dir runtime_probe ready_file stop_file pid supervisor_cmdline runtime_output cmdline_path candidate_pid candidate_cmdline
  if [ ! -d /proc/$$ ]; then
    return 0
  fi

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  runtime_probe="$tmp_dir/runtime-probe"
  ready_file="$tmp_dir/ready"
  stop_file="$tmp_dir/stop"

  cat > "$runtime_probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'runtime_argv0=%s\n' "$0" > "$AGENT_RUNTIME_READY_FILE"
printf 'runtime_args=%s\n' "$*" >> "$AGENT_RUNTIME_READY_FILE"
cp "$AGENT_RUNTIME_READY_FILE" "${AGENT_RUNTIME_READY_FILE}.copy"

while [ ! -e "$AGENT_RUNTIME_STOP_FILE" ]; do
  sleep 0.05
done
EOF
  chmod +x "$runtime_probe"

  logical_runtime_argv0_for codex "$runtime_probe" "$ready_file" "$stop_file" &
  pid=$!

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$ready_file.copy" ] && break
    sleep 0.05
  done

  [ -f "$ready_file.copy" ] || fail "runtime probe did not start"

  supervisor_cmdline=""
  for cmdline_path in /proc/[0-9]*/cmdline; do
    [ -r "$cmdline_path" ] || continue
    candidate_pid="${cmdline_path#/proc/}"
    candidate_pid="${candidate_pid%/cmdline}"
    process_is_descendant_of "$pid" "$candidate_pid" || continue
    candidate_cmdline="$(tr '\0' ' ' <"$cmdline_path" 2>/dev/null || true)"
    case "$candidate_cmdline" in
      codex\ -c*)
        supervisor_cmdline="$candidate_cmdline"
        break
        ;;
    esac
  done

  runtime_output="$(cat "$ready_file.copy")"
  : > "$stop_file"
  wait "$pid"

  assert_contains "$supervisor_cmdline" "codex -c"
  assert_contains "$runtime_output" "runtime_argv0=$runtime_probe"
  assert_contains "$runtime_output" "runtime_args=run alpha beta"
)

test_host_home_fallbacks_present() (
  set -euo pipefail

  local environment_file
  environment_file="$(cat "$REPO_ROOT/bin/lib/environment.sh")"

  assert_contains "$environment_file" 'if [ -z "$HOST_HOME" ] && [ -n "${USER:-}" ] && [ -d "/home/$USER" ]; then'
  assert_contains "$environment_file" 'if [ -z "$HOST_HOME" ] && [ -n "${LOGNAME:-}" ] && [ -d "/home/$LOGNAME" ]; then'
  assert_contains "$environment_file" 'done < <(find /home -mindepth 1 -maxdepth 1 -type d -user "$(id -u)" 2>/dev/null)'
  assert_contains "$environment_file" 'done < <(find /Users -mindepth 1 -maxdepth 1 -type d -user "$(id -u)" 2>/dev/null)'
  assert_contains "$environment_file" 'project_root_tail="${PROJECT_ROOT#/home/}"'
  assert_contains "$environment_file" 'project_root_tail="${PROJECT_ROOT#/Users/}"'
)

test_stable_fetchtarball_uses_lock() (
  set -euo pipefail

  local output
  output="$(pin_shell_fetchtarball_for "https://example.com/nixpkgs-abc123.tar.gz" "cachedhash" "freshhash")"

  assert_contains "$output" "pinned={\"url\":\"https://example.com/nixpkgs-abc123.tar.gz\",\"sha256\":\"cachedhash\"}"
  assert_contains "$output" "lock={\"url\":\"https://example.com/nixpkgs-abc123.tar.gz\",\"sha256\":\"cachedhash\"}"
  assert_contains "$output" "calls=0"
  assert_contains "$output" "(locked; remove "
  assert_contains "$output" " to refresh)"
)

test_mutable_channel_fetchtarball_uses_lock() (
  set -euo pipefail

  local output
  output="$(pin_shell_fetchtarball_for "https://nixos.org/channels/nixpkgs-unstable/nixexprs.tar.xz" "stalehash" "freshhash")"

  assert_contains "$output" "pinned={\"url\":\"https://nixos.org/channels/nixpkgs-unstable/nixexprs.tar.xz\",\"sha256\":\"stalehash\"}"
  assert_contains "$output" "lock={\"url\":\"https://nixos.org/channels/nixpkgs-unstable/nixexprs.tar.xz\",\"sha256\":\"stalehash\"}"
  assert_contains "$output" "calls=0"
  assert_contains "$output" "(locked; remove "
  assert_not_contains "$output" "freshhash"
)

test_missing_fetchtarball_lock_is_created() (
  set -euo pipefail

  local output
  output="$(pin_shell_fetchtarball_for "https://nixos.org/channels/nixpkgs-unstable/nixexprs.tar.xz" "" "freshhash")"

  assert_contains "$output" "pinned={\"url\":\"https://nixos.org/channels/nixpkgs-unstable/nixexprs.tar.xz\",\"sha256\":\"freshhash\"}"
  assert_contains "$output" "lock={\"url\":\"https://nixos.org/channels/nixpkgs-unstable/nixexprs.tar.xz\",\"sha256\":\"freshhash\"}"
  assert_contains "$output" "calls=1"
  assert_contains "$output" "prefetch=called --option tarball-ttl 0 --unpack https://nixos.org/channels/nixpkgs-unstable/nixexprs.tar.xz"
  assert_contains "$output" "(created lock "
)

test_shell_nix_nix_path_default_receives_explicit_pkgs() (
  set -euo pipefail

  local tmp_dir project_dir output
  tmp_dir="$(mktemp -d)"
  project_dir="$tmp_dir/project"
  mkdir -p "$project_dir"
  trap 'chmod -R u+w "$tmp_dir" 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT

  printf '%s\n' \
    '{ pkgs ? import <nixpkgs> {} }:' \
    'pkgs.mkShell { packages = [ pkgs.hello ]; }' \
    > "$project_dir/shell.nix"

  output="$(
    env -u NIX_CONFIG \
      NIX_REMOTE="local?root=$tmp_dir/nix-root" \
      NIX_PATH= \
      AGENT_TEST_PROJECT="$project_dir" \
      AGENT_TEST_REPO_ROOT="$REPO_ROOT" \
      nix --extra-experimental-features 'nix-command flakes' eval --impure --json --expr '
        let
          projectPkgs = builtins.path {
            path = builtins.getEnv "AGENT_TEST_PROJECT";
            name = "agent-shell-contract-test";
          };
          detector = builtins.toPath ((builtins.getEnv "AGENT_TEST_REPO_ROOT") + "/nix/detect-packages.nix");
        in
        import detector {
          pkgs = {
            system = "test-system";
            hello = "hello";
            mkShell = attrs: attrs;
          };
          unstable = { };
          inherit projectPkgs;
        }
      '
  )"

  [ "$output" = '["hello"]' ] || fail "expected explicit pkgs injection, got: $output"
)

test_symlinked_shell_stages_resolved_nix_contract() (
  set -euo pipefail

  local output
  output="$(stage_symlinked_shell_contract)"

  assert_contains "$output" "shell_is_symlink=0"
  assert_contains "$output" "shell={ pkgs ? import <nixpkgs> {} }: import ./nix/default.nix { inherit pkgs; }"
  assert_contains "$output" "default={ pkgs }: []"
  assert_contains "$output" "template=font template"
)

test_image_uses_standard_git() (
  set -euo pipefail

  local image_file
  image_file="$(cat "$REPO_ROOT/nix/image.nix")"

  assert_contains "$image_file" '      pkgs.git'
  assert_not_contains "$image_file" 'writeShellScriptBin "git"'
)

test_device_passthrough_support() (
  set -euo pipefail

  local runtime_file config_file readme_file
  runtime_file="$(cat "$REPO_ROOT/bin/lib/container_runtime.sh")"
  config_file="$(cat "$REPO_ROOT/docs/CONFIG.md")"
  readme_file="$(cat "$REPO_ROOT/README.md")"

  assert_contains "$runtime_file" 'append_split_arg_values --device "$device_specs"'
  assert_contains "$runtime_file" 'AGENT_ALLOW_KVM'
  assert_contains "$config_file" '`AGENT_EXTRA_DEVICES`'
  assert_contains "$config_file" '`AGENT_ALLOW_KVM=1`'
  assert_contains "$readme_file" '`AGENT_EXTRA_DEVICES`'
)

test_kvm_smoke_script() (
  set -euo pipefail

  local script_file
  script_file="$(cat "$REPO_ROOT/tests/kvm-smoke.sh")"

  assert_contains "$script_file" 'need inject qemu'
  assert_contains "$script_file" '-accel kvm'
  assert_contains "$script_file" '-M microvm'
  assert_contains "$script_file" 'MICROVM_TEST_TIMEOUT'
)

test_bun_latest_lookup_uses_tool_cache() (
  set -euo pipefail

  local image_file
  image_file="$(cat "$REPO_ROOT/nix/image.nix")"

  assert_contains "$image_file" "requested_version=\"''\${AGENT_CODEX_VERSION:-}\""
  assert_contains "$image_file" 'if [ "$requested_version" = "latest" ]; then'
  assert_contains "$image_file" 'Installing ${pkg}@$requested_version...'
  assert_contains "$image_file" '${pkgs.bun}/bin/bun add --trust "${pkg}@$requested_version"'
  assert_contains "$image_file" 'latest_version="$((cd "$CACHE_DIR" && ${pkgs.bun}/bin/bun info ${pkg} version) 2>/dev/null | head -n1 || true)"'
)

test_codex_bubblewrap_compat_path() (
  set -euo pipefail

  local image_file readme_file
  image_file="$(cat "$REPO_ROOT/nix/image.nix")"
  readme_file="$(cat "$REPO_ROOT/README.md")"

  assert_contains "$image_file" 'bubblewrapCompat = pkgs.runCommand "bubblewrap-compat"'
  assert_contains "$image_file" 'version = "0.12.0"'
  assert_contains "$image_file" 'rev = "v0.12.0"'
  assert_contains "$image_file" 'ln -s ${bubblewrap}/bin/bwrap "$out/usr/bin/bwrap"'
  assert_contains "$readme_file" '`agent codex` can use Codex'\''s native Bubblewrap sandbox inside the outer container because the image provides upstream Bubblewrap 0.12.0 at `/usr/bin/bwrap`.'
)

test_workspace_mounts_for_regular_repo_workspace_override() (
  set -euo pipefail

  local tmp_dir repo workspace git_top output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  repo="$tmp_dir/repo"
  workspace="$repo/subdir"
  mkdir -p "$workspace"
  git -C "$repo" init -q
  printf 'hello\n' > "$repo/file.txt"
  printf 'nested\n' > "$workspace/nested.txt"
  git -C "$repo" add file.txt subdir/nested.txt
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -qm init

  git_top="$(git -C "$workspace" rev-parse --show-toplevel)"
  output="$(workspace_mount_args_for "$workspace")"

  assert_contains "$output" "$git_top:$git_top:rw"
)

test_workspace_mounts_for_linked_worktree_workspace_override() (
  set -euo pipefail

  local tmp_dir repo workspace worktree git_top git_common_dir output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  repo="$tmp_dir/repo"
  worktree="$tmp_dir/worktree"
  mkdir -p "$repo/subdir"
  git -C "$repo" init -q
  printf 'hello\n' > "$repo/file.txt"
  printf 'nested\n' > "$repo/subdir/nested.txt"
  git -C "$repo" add file.txt subdir/nested.txt
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -qm init
  git -C "$repo" worktree add -q "$worktree" -b feature

  workspace="$worktree/subdir"
  git_top="$(git -C "$workspace" rev-parse --show-toplevel)"
  git_common_dir="$(
    cd "$workspace" &&
    cd "$(git -C "$workspace" rev-parse --git-common-dir)" &&
    pwd -P
  )"
  output="$(workspace_mount_args_for "$workspace")"

  [ "$git_common_dir" != "$git_top" ] || fail "expected linked worktree common dir to differ from worktree top-level"
  assert_contains "$output" "$git_top:$git_top:rw"
  assert_contains "$output" "$git_common_dir:$git_common_dir:rw"
)

test_config_selectors_are_not_passthrough_env() (
  set -euo pipefail

  local output
  output="$(
    env \
      CODEX_CONFIG=project \
      CODEX_AUTH=work \
      OPENCODE_CONFIG=fresh \
      CLAUDE_AUTH=other \
      CODEX_FOO=bar \
      REPO_ROOT="$REPO_ROOT" \
      bash -lc '
        split_csv_or_lines() {
          local value="$1"
          printf "%s\n" "$value" | tr "," "\n" | sed "/^[[:space:]]*$/d"
        }
        source "$REPO_ROOT/bin/lib/container_runtime.sh"
        ARGS=()
        append_passthrough_env_args
        printf "%s\n" "${ARGS[@]}"
      '
  )"

  assert_not_contains "$output" "CODEX_CONFIG=project"
  assert_not_contains "$output" "CODEX_AUTH=work"
  assert_not_contains "$output" "OPENCODE_CONFIG=fresh"
  assert_not_contains "$output" "CLAUDE_AUTH=other"
  assert_not_contains "$output" "SSH_AUTH_SOCK="
  assert_contains "$output" "CODEX_FOO=bar"
)

test_ssh_agent_mount_support() (
  set -euo pipefail

  local socket_path output
  socket_path="/tmp/test-ssh-agent.sock"

  output="$(ssh_agent_args_for "$socket_path")"

  assert_contains "$output" "$socket_path:/run/host-services/ssh-auth.sock:rw"
  assert_contains "$output" "SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock"
)

test_remote_mode_suppresses_ssh_agent_by_default() (
  set -euo pipefail

  local socket_path output
  socket_path="/tmp/test-ssh-agent.sock"

  output="$(
    AGENT_REMOTE_CONTAINER_MODE=1 ssh_agent_args_for "$socket_path"
  )"

  assert_not_contains "$output" "$socket_path:/run/host-services/ssh-auth.sock:rw"
  assert_not_contains "$output" "SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock"

  output="$(
    AGENT_REMOTE_CONTAINER_MODE=1 AGENT_REMOTE_FORWARD_SSH_AGENT=1 ssh_agent_args_for "$socket_path"
  )"

  assert_contains "$output" "$socket_path:/run/host-services/ssh-auth.sock:rw"
  assert_contains "$output" "SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock"
)

test_remote_secrets_are_not_passthrough_env() (
  set -euo pipefail

  local output
  output="$(
    env \
      AGENT_REMOTE_TS_AUTHKEY=tskey-secret \
      AGENT_REMOTE_TAILSCALE_AUTHKEY=tskey-secret-2 \
      TS_AUTHKEY=tskey-secret-3 \
      AGENT_REMOTE_TS_CLIENT_SECRET=ts-secret \
      TS_CLIENT_SECRET=ts-secret-2 \
      AGENT_REMOTE_NAME=remote-name \
      REPO_ROOT="$REPO_ROOT" \
      bash -lc '
        split_csv_or_lines() {
          local value="$1"
          printf "%s\n" "$value" | tr "," "\n" | sed "/^[[:space:]]*$/d"
        }
        source "$REPO_ROOT/bin/lib/container_runtime.sh"
        AGENT_REMOTE_CONTAINER_MODE=1
        ARGS=()
        append_passthrough_env_args
        printf "%s\n" "${ARGS[@]}"
      '
  )"

  assert_not_contains "$output" "AGENT_REMOTE_TS_AUTHKEY=tskey-secret"
  assert_not_contains "$output" "AGENT_REMOTE_TAILSCALE_AUTHKEY=tskey-secret-2"
  assert_not_contains "$output" "TS_AUTHKEY=tskey-secret-3"
  assert_not_contains "$output" "AGENT_REMOTE_TS_CLIENT_SECRET=ts-secret"
  assert_not_contains "$output" "TS_CLIENT_SECRET=ts-secret-2"
  assert_not_contains "$output" "AGENT_REMOTE_NAME=remote-name"
)

test_remote_host_env_opt_in_restores_agent_passthrough() (
  set -euo pipefail

  local output
  output="$(
    env \
      AGENT_REMOTE_NAME=remote-name \
      REPO_ROOT="$REPO_ROOT" \
      bash -lc '
        split_csv_or_lines() {
          local value="$1"
          printf "%s\n" "$value" | tr "," "\n" | sed "/^[[:space:]]*$/d"
        }
        source "$REPO_ROOT/bin/lib/container_runtime.sh"
        AGENT_REMOTE_CONTAINER_MODE=1
        AGENT_REMOTE_ALLOW_HOST_ENV=1
        ARGS=()
        append_passthrough_env_args
        printf "%s\n" "${ARGS[@]}"
      '
  )"

  assert_contains "$output" "AGENT_REMOTE_NAME=remote-name"
)

remote_reject_output_for() (
  set -euo pipefail

  source "$REPO_ROOT/bin/lib/remote.sh"
  remote_reject_implicit_host_bridges
)

test_remote_rejects_broad_bridges_by_default() (
  set -euo pipefail

  local output status

  set +e
  output="$(AGENT_CONTAINER_API=none AGENT_NEED_HELPER=0 AGENT_EXTRA_MOUNTS=/host:/guest remote_reject_output_for 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "expected AGENT_EXTRA_MOUNTS to be rejected"
  assert_contains "$output" "remote mode does not inherit AGENT_EXTRA_MOUNTS by default"

  set +e
  output="$(AGENT_CONTAINER_API=none AGENT_NEED_HELPER=0 AGENT_EXTRA_DEVICES=/dev/kvm remote_reject_output_for 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "expected AGENT_EXTRA_DEVICES to be rejected"
  assert_contains "$output" "remote mode does not inherit extra devices by default"

  set +e
  output="$(AGENT_CONTAINER_API=none AGENT_NEED_HELPER=0 AGENT_EXTRA_ENV=FOO=bar remote_reject_output_for 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "expected AGENT_EXTRA_ENV to be rejected"
  assert_contains "$output" "remote mode does not inherit AGENT_EXTRA_ENV by default"
)

test_remote_forces_safe_helper_defaults() (
  set -euo pipefail

  local output
  output="$(
    AGENT_CONTAINER_API=auto AGENT_NEED_HELPER=1 bash -c '
      source "$1"
      remote_reject_implicit_host_bridges
      printf "container_api=%s\n" "$AGENT_CONTAINER_API"
      printf "need_helper=%s\n" "$AGENT_NEED_HELPER"
    ' bash "$REPO_ROOT/bin/lib/remote.sh" 2>&1
  )"

  assert_contains "$output" "remote mode forcing AGENT_CONTAINER_API=none"
  assert_contains "$output" "remote mode forcing AGENT_NEED_HELPER=0"
  assert_contains "$output" "container_api=none"
  assert_contains "$output" "need_helper=0"
)

test_remote_defaults_codex_config_to_project() (
  set -euo pipefail

  local output
  output="$(
    bash -c '
      source "$1"
      unset CODEX_CONFIG
      remote_apply_defaults
      printf "default=%s\n" "$CODEX_CONFIG"
      CODEX_CONFIG=host
      remote_apply_defaults
      printf "explicit=%s\n" "$CODEX_CONFIG"
    ' bash "$REPO_ROOT/bin/lib/remote.sh"
  )"

  assert_contains "$output" "default=project"
  assert_contains "$output" "explicit=host"
)

test_remote_light_bootstrap_skips_firecracker_confirmation() (
  set -euo pipefail

  local tmp_dir output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  mkdir -p "$tmp_dir/workspace"

  output="$(
    AGENT_WORKSPACE_PATH="$tmp_dir/workspace" bash -c '
      source "$1"
      hash_short() { printf "1234567890abcdef\n"; }
      prepare_tool_resolution_context() { PROJECT_ROOT="$2/workspace"; }
      resolve_sandbox_profile() {
        SANDBOX_PROFILE=firecracker-host
        AGENT_SANDBOX_PROFILE=firecracker-host
      }
      resolve_runtime() { RUNTIME=podman; }
      prepare_cache_dirs() { CACHE_DIR="$2/cache"; mkdir -p "$CACHE_DIR"; }
      bootstrap_environment() { :; }
      remote_firecracker_confirmation() { printf "confirmed\n"; }

      remote_bootstrap_light
      printf "light_workspace=%s\n" "$WORKSPACE_PATH"
      remote_bootstrap_full
      printf "full_without_confirm_done=1\n"
      remote_bootstrap_full confirm-firecracker
    ' bash "$REPO_ROOT/bin/lib/remote.sh" "$tmp_dir"
  )"

  assert_contains "$output" "light_workspace=$tmp_dir/workspace"
  assert_contains "$output" "full_without_confirm_done=1"
  assert_contains "$output" "confirmed"
)

test_remote_requires_tailscale_auth_before_starting() (
  set -euo pipefail

  local tmp_dir output status
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  set +e
  output="$(
    REMOTE_TS_CONTAINER=agent-remote-test-ts \
    REMOTE_TS_STATE_DIR="$tmp_dir/tailscale" \
    bash -c '
      source "$1"
      podman_runtime_cmd() {
        return 1
      }
      remote_require_tailscale_auth_available
    ' bash "$REPO_ROOT/bin/lib/remote.sh" 2>&1
  )"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected missing Tailscale auth to fail"
  assert_contains "$output" "first remote start needs Tailscale auth"
)

test_remote_up_preflights_auth_before_artifacts() (
  set -euo pipefail

  local output status

  set +e
  output="$(
    bash -c '
      source "$1"
      remote_bootstrap_full() { :; }
      remote_require_podman_default_profile() { :; }
      remote_reject_implicit_host_bridges() { :; }
      remote_require_tailscale_auth_available() {
        echo "auth-preflight"
        exit 7
      }
      remote_prepare_authorized_keys() { echo "authorized-keys"; }
      prepare_runtime_artifacts() { echo "artifacts"; }
      prepare_container_api() { :; }
      prepare_need_helper() { :; }
      log_debug_context() { :; }
      remote_create_pod() { :; }
      remote_start_runtime_container() { :; }
      remote_start_tailscale_sidecar() { :; }
      remote_configure_tailscale_serve() { :; }
      remote_print_status() { :; }
      remote_run_up
    ' bash "$REPO_ROOT/bin/lib/remote.sh"
  )"
  status=$?
  set -e

  [ "$status" -eq 7 ] || fail "expected auth preflight to stop remote up"
  assert_contains "$output" "auth-preflight"
  assert_not_contains "$output" "authorized-keys"
  assert_not_contains "$output" "artifacts"
)

test_remote_pod_has_no_published_ports() (
  set -euo pipefail

  local tmp_dir output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  output="$(
    CMD_LOG="$tmp_dir/cmd.log" bash -c '
      source "$1"
      REMOTE_POD_NAME=agent-remote-test
      firecracker_host_profile() { return 1; }
      remote_pod_exists() { return 1; }
      podman_runtime_cmd() { printf "%s\n" "$*" >> "$CMD_LOG"; }
      remote_create_pod
      cat "$CMD_LOG"
    ' bash "$REPO_ROOT/bin/lib/remote.sh"
  )"

  assert_contains "$output" "pod create --name agent-remote-test --network=slirp4netns:allow_host_loopback=true"
  assert_not_contains "$output" "--network=host"
  assert_not_contains "$output" "-p "
  assert_not_contains "$output" "--publish"
)

test_remote_tailscale_sidecar_uses_userspace_pod_network() (
  set -euo pipefail

  local tmp_dir output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  mkdir -p "$tmp_dir/ts"

  output="$(
    CMD_LOG="$tmp_dir/cmd.log" bash -c '
      source "$1"
      REMOTE_POD_NAME=agent-remote-test
      REMOTE_TS_CONTAINER=agent-remote-test-ts
      REMOTE_TS_STATE_DIR="$2/ts"
      REMOTE_HOSTNAME=codex-test
      AGENT_REMOTE_TS_AUTHKEY=tskey-test
      firecracker_host_profile() { return 1; }
      remote_container_running() { return 1; }
      podman_runtime_cmd() { printf "%s\n" "$*" >> "$CMD_LOG"; }
      remote_start_tailscale_sidecar
      cat "$CMD_LOG"
    ' bash "$REPO_ROOT/bin/lib/remote.sh" "$tmp_dir"
  )"

  assert_contains "$output" "run -d --init --pod agent-remote-test --name agent-remote-test-ts --replace"
  assert_contains "$output" "TS_HOSTNAME=codex-test"
  assert_contains "$output" "TS_USERSPACE=true"
  assert_contains "$output" "TS_AUTH_ONCE=true"
  assert_contains "$output" "TS_EXTRA_ARGS=--advertise-tags=tag:codex-agent"
  assert_not_contains "$output" "--network=host"
  assert_not_contains "$output" "--privileged"
  assert_not_contains "$output" "--cap-add"
  assert_not_contains "$output" "--device"
  assert_not_contains "$output" "-p "
  assert_not_contains "$output" "--publish"
)

test_remote_firecracker_tailscale_sidecar_uses_host_network_init() (
  set -euo pipefail

  local tmp_dir output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  mkdir -p "$tmp_dir/ts"

  output="$(
    CMD_LOG="$tmp_dir/cmd.log" bash -c '
      source "$1"
      REMOTE_TS_CONTAINER=agent-remote-test-ts
      REMOTE_TS_STATE_DIR="$2/ts"
      REMOTE_HOSTNAME=codex-test
      AGENT_REMOTE_TS_AUTHKEY=tskey-test
      firecracker_host_profile() { return 0; }
      remote_container_running() { return 1; }
      podman_runtime_cmd() { printf "%s\n" "$*" >> "$CMD_LOG"; }
      remote_start_tailscale_sidecar
      cat "$CMD_LOG"
    ' bash "$REPO_ROOT/bin/lib/remote.sh" "$tmp_dir"
  )"

  assert_contains "$output" "run -d --init --network=host --name agent-remote-test-ts --replace"
  assert_not_contains "$output" "--pod"
  assert_not_contains "$output" "--privileged"
  assert_not_contains "$output" "--cap-add"
  assert_not_contains "$output" "--device"
)

test_remote_sessions_text_distinguishes_live_and_transcripts() (
  set -euo pipefail

  local output
  output="$(
    source "$REPO_ROOT/bin/lib/remote.sh"
    doctor_line() {
      printf "%s=%s\n" "$1" "$2"
    }
    REMOTE_NAME=test
    WORKSPACE_PATH=/workspace
    remote_sessions_text $'codex\t1\t1' $'2026-01-01T00:00:00Z\tabc123\t/workspace\tmain\t0.1.0\t/tmp/session.jsonl'
  )"

  assert_contains "$output" "Live tmux sessions"
  assert_contains "$output" "codex"
  assert_contains "$output" "Resumable Codex transcripts"
  assert_contains "$output" "abc123"
)

test_remote_codex_noninteractive_starts_without_attach() (
  set -euo pipefail

  local tmp_dir output calls
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  cat > "$tmp_dir/tmux" <<'EOF_TMUX'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TMUX_CALL_LOG"
case "$1" in
  has-session)
    exit 1
    ;;
  new-session)
    exit 0
    ;;
  attach-session)
    echo "attach should not run without a tty" >&2
    exit 99
    ;;
esac
EOF_TMUX
  chmod +x "$tmp_dir/tmux"

  output="$(
    TMUX_CALL_LOG="$tmp_dir/calls" \
      PATH="$tmp_dir:$PATH" \
      AGENT_WORKSPACE_PATH="$REPO_ROOT" \
      sh "$REPO_ROOT/scripts/image/remote-codex.sh" </dev/null
  )"
  calls="$(cat "$tmp_dir/calls")"

  assert_contains "$output" "agent-remote: started Codex session 'codex'"
  assert_contains "$calls" "has-session -t codex"
  assert_contains "$calls" "new-session -d -s codex"
  assert_not_contains "$calls" "attach-session"
)

test_ssh_runtime_generation() (
  set -euo pipefail

  local tmp_dir host_home ssh_dir runtime_dir wrapper_config host_config include_config known_hosts_file mount_args codex_sandbox_args workspace
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  host_home="$tmp_dir/host-home"
  ssh_dir="$host_home/.ssh"
  workspace="$tmp_dir/workspace"
  mkdir -p "$ssh_dir/config.d" "$tmp_dir/tool-cache" "$workspace/.codex"

  cat > "$ssh_dir/config" <<EOF
Host *
        IdentityAgent ~/.1password/agent.sock
        ServerAliveInterval 60

Host trunk.koker.net
    ProxyCommand cloudflared access ssh --hostname %h
    User git

Include $host_home/.ssh/config.d/*.conf
EOF

  cat > "$ssh_dir/config.d/work.conf" <<'EOF'
Host github.com
    User git
EOF

  printf 'trunk.koker.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey\n' > "$ssh_dir/known_hosts"
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n' > "$ssh_dir/id_ed25519"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPublicKey user@example\n' > "$ssh_dir/id_ed25519.pub"

  runtime_dir="$(prepare_ssh_runtime_for "$host_home" "$tmp_dir/tool-cache" "/tmp/host-ssh-agent.sock" "codex" "$workspace")"
  [ -n "$runtime_dir" ] || fail "expected ssh runtime dir to be created"

  wrapper_config="$(cat "$runtime_dir/config")"
  host_config="$(cat "$runtime_dir/config.host")"
  include_config="$(cat "$runtime_dir/config.d/work.conf")"
  known_hosts_file="$(cat "$runtime_dir/known_hosts")"
  mount_args="$(ssh_runtime_mount_args_for "$runtime_dir")"
  codex_sandbox_args="$(codex_ssh_sandbox_args_for "$runtime_dir" "/tmp/host-ssh-agent.sock")"

  assert_contains "$wrapper_config" "IdentityAgent /run/host-services/ssh-auth.sock"
  assert_contains "$wrapper_config" "UserKnownHostsFile /cache/.ssh/known_hosts /cache/.ssh/known_hosts2"
  assert_contains "$wrapper_config" "Include /cache/.ssh/config.host"
  assert_contains "$host_config" "IdentityAgent ~/.1password/agent.sock"
  assert_contains "$host_config" "ProxyCommand cloudflared access ssh --hostname %h"
  assert_contains "$host_config" "Include /cache/.ssh/config.d/*.conf"
  assert_contains "$include_config" "Host github.com"
  assert_contains "$known_hosts_file" "trunk.koker.net ssh-ed25519"
  [ ! -e "$runtime_dir/id_ed25519" ] || fail "expected private key to be excluded from ssh runtime"
  [ -f "$runtime_dir/id_ed25519.pub" ] || fail "expected public key to be copied into ssh runtime"
  assert_contains "$mount_args" "$runtime_dir:/cache/.ssh:ro"
  assert_contains "$codex_sandbox_args" "--add-dir"
  assert_contains "$codex_sandbox_args" "/cache/.ssh"
  assert_contains "$codex_sandbox_args" "/run/host-services"
  [ ! -e "$workspace/.agent-sandbox-codex-ssh" ] || fail "expected no codex ssh alias in the workspace"
)

test_dev_env_path_precedence() (
  set -euo pipefail

  local tmp_dir workspace env_file output path_line
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  mkdir -p "$workspace"
  env_file="$tmp_dir/dev.env"
  printf 'PATH=/nix/store/bun/bin:/nix/store/node/bin:/bin\n' > "$env_file"

  output="$(dev_env_args_for "$workspace" "$workspace" "$env_file")"
  path_line="$(printf '%s\n' "$output" | sed -n 's/^PATH=//p')"

  case "$path_line" in
    "/run/agent-path-guard:$workspace/node_modules/.bin:/nix/store/bun/bin:/nix/store/node/bin:/bin:"*) ;;
    *) fail "dev env PATH should come before need/image fallback paths: $path_line" ;;
  esac
  assert_contains "$path_line" ":/cache/need/projects/"
  assert_not_contains "$path_line" "/cache/need/bin"
  assert_not_contains "$path_line" "/agent-sudo/bin"
)

test_runtime_path_uses_project_scoped_need_bins() (
  set -euo pipefail

  local tmp_dir workspace output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  mkdir -p "$workspace"

  output="$(runtime_path_for "$workspace" "$workspace")"

  case "$output" in
    "/run/agent-path-guard:$workspace/node_modules/.bin:/cache/need/projects/"*) ;;
    *) fail "runtime PATH should use project-scoped need bins after project-local bins: $output" ;;
  esac
  assert_not_contains "$output" "/cache/need/bin"
  assert_not_contains "$output" "/agent-sudo/bin"
)

test_runtime_path_includes_sudo_when_enabled() (
  set -euo pipefail

  local tmp_dir workspace output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  mkdir -p "$workspace"

  output="$(runtime_path_for "$workspace" "$workspace" "" 1)"

  case "$output" in
    "/run/agent-path-guard:/agent-sudo/bin:$workspace/node_modules/.bin:/cache/need/projects/"*) ;;
    *) fail "runtime PATH should include sudo path when enabled: $output" ;;
  esac
)

test_runtime_modes_preserve_podman_rootfs() (
  set -euo pipefail

  local output status

  output="$(runtime_mode_for podman)"
  assert_contains "$output" "podman-rootfs"

  output="$(runtime_mode_for docker)"
  assert_contains "$output" "docker-oci"

  set +e
  output="$(runtime_mode_for podman "ssh://podman.example" 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected remote podman runtime mode to fail"
  assert_contains "$output" "podman mode requires local Linux with /nix/store and no CONTAINER_HOST"
)

test_firecracker_profile_rejects_docker_runtime() (
  set -euo pipefail

  local output status

  set +e
  output="$(runtime_mode_for docker "" firecracker-host 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected firecracker-host profile to reject docker"
  assert_contains "$output" "AGENT_SANDBOX_PROFILE=firecracker-host supports only podman rootfs mode"
)

test_rootless_linux_profile_rejects_docker_runtime() (
  set -euo pipefail

  local output status

  set +e
  output="$(runtime_mode_for docker "" rootless-linux 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected rootless-linux profile to reject docker"
  assert_contains "$output" "AGENT_SANDBOX_PROFILE=rootless-linux supports only podman rootfs mode"
)

test_stream_image_helper_uses_docker_helper_attr() (
  set -euo pipefail

  local output
  output="$(stream_image_helper_invocation_for)"

  assert_contains "$output" "TMPDIR="
  assert_contains "$output" "/cache/tmp"
  assert_contains "$output" "argv=run path:/sandbox#streamImage.copyToDockerDaemon --override-input projectPkgs path:/project-store --no-update-lock-file -- --probe flag"
)

test_runtime_identity_masks_sudo_by_default() (
  set -euo pipefail

  local output
  output="$(runtime_identity_args_for)"

  assert_contains "$output" "/etc/passwd:ro"
  assert_contains "$output" "/etc/group:ro"
  assert_contains "$output" ":/agent-sudo:ro"
  assert_not_contains "$output" "/etc/sudo.conf:ro"
  assert_not_contains "$output" "/etc/sudoers:ro"
  assert_not_contains "$output" "/agent-sudo/bin/sudo:ro"
  assert_not_contains "$output" "/agent-sudo/bin/sudoedit:ro"
  assert_contains "$output" "USER=agenttest"
  assert_contains "$output" "LOGNAME=agenttest"
  assert_contains "$output" "agenttest:x:"
  assert_contains "$output" "sudo_disabled_mask=1"
  assert_not_contains "$output" "sudo_mode=4755"
)

test_runtime_identity_mounts_sudo_overlay_when_enabled() (
  set -euo pipefail

  local output
  output="$(runtime_identity_args_for 1)"

  assert_contains "$output" "/etc/passwd:ro"
  assert_contains "$output" "/etc/group:ro"
  assert_contains "$output" "/etc/sudo.conf:ro"
  assert_contains "$output" "/etc/sudoers:ro"
  assert_contains "$output" "/agent-sudo/bin/sudo:ro"
  assert_contains "$output" "/agent-sudo/bin/sudoedit:ro"
  assert_contains "$output" "USER=agenttest"
  assert_contains "$output" "LOGNAME=agenttest"
  assert_contains "$output" "agenttest:x:"
  assert_contains "$output" "ALL ALL=(ALL:ALL) NOPASSWD:SETENV: ALL"
  assert_contains "$output" "sudo_mode=4755"
  assert_contains "$output" "sudoedit_mode=4755"
  assert_contains "$output" "podman_unshare=chown 1:1"
)

test_stdio_target_uses_podman_rootfs() (
  set -euo pipefail

  local output
  output="$(stdio_target_args_for)"

  assert_contains "$output" "--rootfs"
  assert_contains "$output" "/tmp/rootfs:O"
  assert_not_contains "$output" "sha256:unused"
)

test_rootless_linux_target_uses_private_session_entrypoint() (
  set -euo pipefail

  local output
  output="$(stdio_target_args_for rootless-linux)"

  assert_contains "$output" "AGENT_ROOTLESS_LINUX_TOOL=/bin/codex"
  assert_contains "$output" "/bin/agent-rootless-linux-entrypoint"
  assert_not_contains "$output" "--entrypoint\n/bin/codex"
)

test_rootless_linux_runtime_uses_delegated_user_scope() (
  set -euo pipefail

  local output
  output="$(rootless_runtime_command_for)"

  assert_contains "$output" "logical-argv0=codex"
  assert_contains "$output" "systemd-run"
  assert_contains "$output" "--user"
  assert_contains "$output" "--scope"
  assert_contains "$output" "Delegate=cpu memory pids"
  assert_contains "$output" "podman"
  assert_contains "$output" "--probe"
  assert_not_contains "$output" "sudo"
)

test_runtime_containers_require_pid1_init() (
  set -euo pipefail

  local output=""
  local init_count=""

  for output in \
    "$(base_container_args_for)" \
    "$(base_container_args_for 0 default docker)" \
    "$(base_container_args_for 0 firecracker-host)" \
    "$(base_container_args_for 0 rootless-linux)" \
    "$(remote_base_container_args_for)" \
    "$(remote_base_container_args_for firecracker-host)"
  do
    init_count="$(printf '%s\n' "$output" | grep -c -x -- '--init')"
    [ "$init_count" -eq 1 ] || fail "expected exactly one mandatory --init flag, found $init_count"
    assert_not_contains "$output" "--pid=host"
  done
)

test_remote_base_container_uses_stable_pod() (
  set -euo pipefail

  local output
  output="$(remote_base_container_args_for)"

  assert_contains "$output" "--name"
  assert_contains "$output" "agent-remote-test-runtime"
  assert_contains "$output" "--replace"
  assert_contains "$output" "-d"
  assert_contains "$output" "--pod"
  assert_contains "$output" "agent-remote-test"
  assert_not_contains "$output" "--rm"
)

test_remote_firecracker_base_container_skips_pod() (
  set -euo pipefail

  local output
  output="$(remote_base_container_args_for firecracker-host)"

  assert_contains "$output" "--name"
  assert_contains "$output" "agent-remote-test-runtime"
  assert_contains "$output" "--replace"
  assert_contains "$output" "-d"
  assert_contains "$output" "--privileged"
  assert_contains "$output" "--cap-add=NET_ADMIN"
  assert_contains "$output" "--security-opt=label=disable"
  assert_not_contains "$output" "--pod"
  assert_not_contains "$output" "--rm"
)

test_remote_rootless_linux_profile_is_rejected() (
  set -euo pipefail

  local output status

  set +e
  output="$(remote_base_container_args_for rootless-linux 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected rootless-linux remote container mode to fail"
  assert_contains "$output" "AGENT_SANDBOX_PROFILE=rootless-linux does not support remote container mode"
)

test_remote_target_uses_entrypoint() (
  set -euo pipefail

  local output
  output="$(remote_target_args_for)"

  assert_contains "$output" "AGENT_REMOTE_STATE_DIR=/run/agent-remote"
  assert_contains "$output" "AGENT_WORKSPACE_PATH=/workspace"
  assert_contains "$output" "--entrypoint"
  assert_contains "$output" "/bin/agent-remote-entrypoint"
  assert_contains "$output" "--rootfs"
  assert_contains "$output" "/tmp/rootfs:O"
  assert_not_contains "$output" "-i"
  assert_not_contains "$output" "-t"
  assert_not_contains "$output" "/bin/codex"
  assert_not_contains "$output" "sha256:unused"
)

test_path_guard_excludes_privileged_sudo() (
  set -euo pipefail

  local output
  output="$(path_guard_entries_for)"

  assert_not_contains "$output" "sudo ->"
  assert_not_contains "$output" "sudoedit ->"
)

test_firecracker_path_guard_wraps_podman() (
  set -euo pipefail

  local output

  output="$(path_guard_entries_for)"
  assert_not_contains "$output" "podman ->"

  output="$(path_guard_entries_for firecracker-host)"
  assert_contains "$output" "podman -> /bin/agent-firecracker-podman"
)

test_base_container_disables_sudo_by_default() (
  set -euo pipefail

  local output
  output="$(base_container_args_for)"

  assert_contains "$output" "--cap-drop=ALL"
  assert_contains "$output" "--security-opt=no-new-privileges"
  assert_not_contains "$output" "--cap-add=SETUID"
  assert_not_contains "$output" "--cap-add=SETGID"
)

test_base_container_allows_sudo_when_enabled() (
  set -euo pipefail

  local output
  output="$(base_container_args_for 1)"

  assert_contains "$output" "--cap-drop=ALL"
  assert_contains "$output" "--cap-add=SETUID"
  assert_contains "$output" "--cap-add=SETGID"
  assert_not_contains "$output" "--security-opt=no-new-privileges"
)

test_base_container_uses_firecracker_host_profile() (
  set -euo pipefail

  local output
  output="$(base_container_args_for 0 firecracker-host)"

  assert_contains "$output" "--privileged"
  assert_contains "$output" "--cap-add=NET_ADMIN"
  assert_contains "$output" "--security-opt=label=disable"
  assert_not_contains "$output" "--cap-drop=ALL"
  assert_not_contains "$output" "--security-opt=no-new-privileges"
  assert_not_contains "$output" "--memory=4g"
  assert_not_contains "$output" "--cpus=2"
  assert_not_contains "$output" "--pids-limit=512"
)

test_base_container_uses_rootless_linux_profile() (
  set -euo pipefail

  local output
  output="$(base_container_args_for 0 rootless-linux)"

  assert_contains "$output" "--init"
  assert_contains "$output" "--cgroups=split"
  assert_contains "$output" "--cgroupns=private"
  assert_contains "$output" "--systemd=always"
  assert_contains "$output" "--stop-signal=SIGTERM"
  assert_contains "$output" "/run/user/$(id -u):rw,nosuid,nodev,size=16m,mode=0700,uid=$(id -u),gid=$(id -g)"
  assert_contains "$output" "/run/systemd/system:rw,nosuid,nodev,size=1m,mode=0755,uid=$(id -u),gid=$(id -g)"
  assert_contains "$output" "XDG_RUNTIME_DIR=/run/user/$(id -u)"
  assert_contains "$output" "--cap-drop=ALL"
  assert_contains "$output" "--security-opt=no-new-privileges"
  assert_not_contains "$output" "--privileged"
  assert_not_contains "$output" "--cap-add"
)

test_sudo_flag_rejects_invalid_values() (
  set -euo pipefail

  local output status

  set +e
  output="$(AGENT_ALLOW_SUDO=yes bash -c 'source "$1"; sudo_enabled' bash "$REPO_ROOT/bin/lib/container_runtime.sh" 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected invalid AGENT_ALLOW_SUDO to fail"
  assert_contains "$output" "AGENT_ALLOW_SUDO must be 0 or 1"
)

test_firecracker_profile_requires_sudo() (
  set -euo pipefail

  local output status

  output="$(AGENT_SANDBOX_PROFILE=firecracker-host bash -c 'source "$1"; if sudo_enabled; then printf enabled; fi' bash "$REPO_ROOT/bin/lib/container_runtime.sh")"
  assert_contains "$output" "enabled"

  set +e
  output="$(AGENT_SANDBOX_PROFILE=firecracker-host AGENT_ALLOW_SUDO=0 bash -c 'source "$1"; sudo_enabled' bash "$REPO_ROOT/bin/lib/container_runtime.sh" 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected firecracker-host profile to reject disabled sudo"
  assert_contains "$output" "firecracker-host requires sudo"
)

test_rootless_linux_profile_rejects_sudo() (
  set -euo pipefail

  local output status

  set +e
  output="$(AGENT_SANDBOX_PROFILE=rootless-linux AGENT_ALLOW_SUDO=1 bash -c 'source "$1"; sudo_enabled' bash "$REPO_ROOT/bin/lib/container_runtime.sh" 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected rootless-linux profile to reject sudo"
  assert_contains "$output" "AGENT_SANDBOX_PROFILE=rootless-linux does not permit sudo"
)

test_firecracker_runtime_identity_uses_rootful_sudo_overlay() (
  set -euo pipefail

  local output
  output="$(runtime_identity_args_for 0 firecracker-host)"

  assert_contains "$output" "/etc/sudo.conf:ro"
  assert_contains "$output" "/etc/sudoers:ro"
  assert_contains "$output" "/agent-sudo/bin/sudo:ro"
  assert_contains "$output" "sudo_mode=4755"
  assert_contains "$output" "sudo=-n chown 0:0"
  assert_contains "$output" "sudo=-n chmod 4755"
  assert_not_contains "$output" "podman_unshare=chown 1:1"
)

test_firecracker_runtime_identity_args_use_host_namespaces() (
  set -euo pipefail

  local output
  output="$(runtime_identity_run_args_for firecracker-host)"

  assert_contains "$output" "--userns=host"
  assert_contains "$output" "--cgroupns=host"
  assert_contains "$output" "--network=host"
  assert_contains "$output" "--user"
  assert_contains "$output" "$(id -u):$(id -g)"
  assert_not_contains "$output" "--userns=keep-id"
  assert_not_contains "$output" "slirp4netns"
)

test_firecracker_host_devices_and_cgroup_mount() (
  set -euo pipefail

  local output
  output="$(firecracker_host_args_for)"

  assert_contains "$output" "--device"
  assert_contains "$output" "/dev/kvm"
  assert_contains "$output" "/dev/net/tun"
  assert_contains "$output" "/sys/fs/cgroup:/sys/fs/cgroup:rw"
)

test_firecracker_preflight_accepts_capable_host() (
  set -euo pipefail

  local output
  output="$(firecracker_preflight_for)"

  assert_contains "$output" "preflight-ok"
)

test_firecracker_preflight_rejects_rootless_podman() (
  set -euo pipefail

  local output status

  set +e
  output="$(firecracker_preflight_for rootless 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected rootless podman preflight to fail"
  assert_contains "$output" "firecracker-host preflight failed: rootful podman is required"
)

test_firecracker_preflight_rejects_sudoed_launcher() (
  set -euo pipefail

  local output status

  set +e
  output="$(firecracker_preflight_for sudo-launcher 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected sudoed launcher preflight to fail"
  assert_contains "$output" "firecracker-host preflight failed: do not run the launcher with sudo"
  assert_contains "$output" "firecracker-host invokes sudo -n podman internally"
)

test_firecracker_preflight_rejects_missing_cgroup_v2() (
  set -euo pipefail

  local output status

  set +e
  output="$(firecracker_preflight_for cgroup 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected missing cgroup v2 preflight to fail"
  assert_contains "$output" "firecracker-host preflight failed: cgroup v2 must be mounted at /sys/fs/cgroup"
)

test_firecracker_preflight_rejects_cgroup_control_write_failure() (
  set -euo pipefail

  local output status

  set +e
  output="$(firecracker_preflight_for cgroup-control 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected cgroup control write preflight to fail"
  assert_contains "$output" "firecracker-host preflight failed: root must be able to write cgroup v2 control files"
)

test_firecracker_preflight_rejects_missing_kvm() (
  set -euo pipefail

  local output status

  set +e
  output="$(firecracker_preflight_for kvm 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected missing kvm preflight to fail"
  assert_contains "$output" "firecracker-host preflight failed: /dev/kvm must be present and readable/writable by root"
)

test_firecracker_preflight_rejects_missing_tun() (
  set -euo pipefail

  local output status

  set +e
  output="$(firecracker_preflight_for tun 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected missing tun preflight to fail"
  assert_contains "$output" "firecracker-host preflight failed: /dev/net/tun must be present and readable/writable by root"
)

test_firecracker_preflight_rejects_root_workspace_failure() (
  set -euo pipefail

  local output status

  set +e
  output="$(firecracker_preflight_for workspace 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected workspace preflight to fail"
  assert_contains "$output" "firecracker-host preflight failed: root must be able to write and chown files under the workspace"
)

test_rootless_linux_preflight_accepts_capable_host() (
  set -euo pipefail

  local output
  output="$(rootless_linux_preflight_for)"

  assert_contains "$output" "preflight-ok"
)

test_rootless_linux_preflight_rejects_missing_user_manager() (
  set -euo pipefail

  local output status

  set +e
  output="$(rootless_linux_preflight_for user-manager 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected missing user manager to fail"
  assert_contains "$output" "rootless-linux preflight failed: an active systemd user service manager is required"
)

test_rootless_linux_preflight_rejects_incomplete_delegation() (
  set -euo pipefail

  local output status

  set +e
  output="$(rootless_linux_preflight_for delegation 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected incomplete cgroup delegation to fail"
  assert_contains "$output" "rootless-linux delegation probe: mock delegated controller failure"
  assert_contains "$output" "rootless-linux preflight failed: the user manager must delegate writable CPU, memory, and PID cgroup-v2 controls"
)

test_rootless_linux_preflight_rejects_missing_user_namespaces() (
  set -euo pipefail

  local output status

  set +e
  output="$(rootless_linux_preflight_for userns 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected missing user namespaces to fail"
  assert_contains "$output" "rootless-linux preflight failed: unprivileged user namespaces are unavailable"
)

test_rootless_linux_preflight_rejects_rootful_podman() (
  set -euo pipefail

  local output status

  set +e
  output="$(rootless_linux_preflight_for rootful 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected rootful podman to fail"
  assert_contains "$output" "rootless-linux preflight failed: rootless podman is required"
)

test_rootless_linux_session_contract() (
  set -euo pipefail

  local environment_file script_file image_file flake_file
  environment_file="$(cat "$REPO_ROOT/bin/lib/environment.sh")"
  script_file="$(cat "$REPO_ROOT/scripts/image/rootless-linux-entrypoint.sh")"
  image_file="$(cat "$REPO_ROOT/nix/image.nix")"
  flake_file="$(cat "$REPO_ROOT/flake.nix")"

  assert_contains "$script_file" 'effective_caps="$(awk '\''/^CapEff:/ { print $2; exit }'\'' /proc/self/status)"'
  assert_contains "$script_file" '[ -z "${effective_caps//0/}" ]'
  assert_contains "$script_file" '[ "$cgroup_path" = "/" ]'
  assert_contains "$script_file" "printf '+cpu +memory +pids"
  assert_contains "$script_file" 'exec /lib/systemd/systemd --user --unit=basic.target'
  assert_contains "$script_file" 'SYSTEMD_UNIT_PATH=/example/systemd/user'
  assert_contains "$script_file" 'SYSTEMD_ENVIRONMENT_GENERATOR_PATH='
  assert_contains "$script_file" "--property='Delegate=cpu memory pids'"
  assert_contains "$script_file" 'bwrap_version="$(bwrap --version'
  assert_contains "$script_file" 'bwrap --unshare-user --ro-bind / / -- /bin/true'
  assert_contains "$script_file" "printf 'max\\n' > \"\$probe_path/cpu.max\""
  assert_contains "$script_file" "printf 'max\\n' > \"\$probe_path/memory.max\""
  assert_contains "$script_file" "printf 'max\\n' > \"\$probe_path/pids.max\""
  assert_contains "$environment_file" 'payload_path="$scope_path/rootless-linux-payload.$$"'
  assert_contains "$environment_file" '"$payload_path/cgroup.procs"'
  assert_contains "$environment_file" '"$scope_path/cgroup.subtree_control"'
  assert_contains "$script_file" 'payload_path="$scope_path/capability-payload.$$"'
  assert_contains "$script_file" '"$payload_path/cgroup.procs"'
  assert_contains "$script_file" '"$scope_path/cgroup.subtree_control"'
  assert_contains "$script_file" 'AGENT_ROOTLESS_LINUX_PROBE_ONLY'
  assert_not_contains "$script_file" "sudo"
  assert_not_contains "$script_file" "DBUS_SESSION_BUS_ADDRESS"
  assert_contains "$image_file" 'pkgs.systemdMinimal'
  assert_contains "$image_file" 'rootlessLinuxSession'
  assert_contains "$flake_file" 'pkgs.util-linux'

  assert_contains "$environment_file" '"$probe_path/cpu.max"'
  assert_contains "$environment_file" '"$probe_path/memory.max"'
  assert_contains "$environment_file" '"$probe_path/pids.max"'
)

test_host_gc_root_registration_uses_final_path() (
  set -euo pipefail

  local tmp_dir bin_dir store_path root_path output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  bin_dir="$tmp_dir/bin"
  root_path="$tmp_dir/roots/runtime"
  store_path="$(readlink -f /bin/bash)"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/nix-store" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$FAKE_NIX_STORE_LOG"
root_path=""
store_path=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --add-root)
      root_path="$2"
      shift 2
      ;;
    --indirect)
      shift
      ;;
    *)
      store_path="$1"
      shift
      ;;
  esac
done
mkdir -p "$(dirname "$root_path")"
ln -sfn "$store_path" "$root_path"
EOF
  chmod +x "$bin_dir/nix-store"

  source "$REPO_ROOT/bin/lib/nix_roots.sh"
  FAKE_NIX_STORE_LOG="$tmp_dir/nix-store.log"
  export FAKE_NIX_STORE_LOG
  PATH="$bin_dir:/usr/bin:/bin" register_host_gc_root "$store_path" "$root_path"

  output="$(cat "$FAKE_NIX_STORE_LOG")"
  assert_contains "$output" "--add-root $root_path --indirect --realise $store_path"
  [ "$(readlink -f "$root_path")" = "$store_path" ] || fail "expected final-path GC root"
)

test_runtime_lease_retains_artifact_and_mounts_receipts() (
  set -euo pipefail

  local tmp_dir bin_dir store_path lease_dir output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  bin_dir="$tmp_dir/bin"
  store_path="$(readlink -f /bin/bash)"
  mkdir -p "$bin_dir" "$tmp_dir/project"

  cat > "$bin_dir/nix-store" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root_path=""
store_path=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --add-root)
      root_path="$2"
      shift 2
      ;;
    --indirect)
      shift
      ;;
    *)
      store_path="$1"
      shift
      ;;
  esac
done
mkdir -p "$(dirname "$root_path")"
ln -sfn "$store_path" "$root_path"
EOF
  cat > "$bin_dir/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{"%s":{"narHash":"sha256-test","narSize":1,"references":[]}}\n' "$FAKE_STORE_PATH"
EOF
  chmod +x "$bin_dir/nix-store" "$bin_dir/nix"

  hash_short() {
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,16)}'
  }
  source "$REPO_ROOT/bin/lib/nix_roots.sh"
  source "$REPO_ROOT/bin/lib/runtime_lease.sh"
  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  CACHE_DIR="$tmp_dir/cache"
  PROJECT_ROOT="$tmp_dir/project"
  AGENT_COMMAND="run"
  FAKE_STORE_PATH="$store_path"
  export FAKE_STORE_PATH
  PATH="$bin_dir:/usr/bin:/bin"
  export PATH

  mkdir -p "$CACHE_DIR/runtime-leases/sandbox-stale"
  {
    printf 'pid=999999999\n'
    printf 'identity=missing\n'
  } > "$CACHE_DIR/runtime-leases/sandbox-stale/owner.env"

  prepare_runtime_lease
  lease_dir="$RUNTIME_LEASE_DIR"
  [ ! -e "$CACHE_DIR/runtime-leases/sandbox-stale" ] || fail "expected stale foreground lease pruning"
  retain_runtime_artifact rootfs "$store_path"

  [ -L "$RUNTIME_LEASE_ROOTS_DIR/runtime-rootfs" ] || fail "expected sandbox-owned runtime root"
  jq -e \
    --arg lease_id "$RUNTIME_LEASE_ID" \
    --arg store_path "$store_path" \
    '.lease_id == $lease_id and .kind == "runtime-artifact" and .output_paths == [$store_path] and (.closure | length) == 1' \
    "$RUNTIME_LEASE_RECEIPTS_DIR/runtime-rootfs.json" >/dev/null
  runtime_lease_has_artifact_receipt || fail "expected retained artifact receipt to validate"

  ARGS=()
  Z_SUFFIX=""
  append_runtime_receipt_mount_args
  output="${ARGS[*]}"
  assert_contains "$output" "$RUNTIME_LEASE_RECEIPTS_DIR:/run/agent-runtime-receipts:ro"
  assert_contains "$output" "AGENT_RUNTIME_LEASE_ID=$RUNTIME_LEASE_ID"
  assert_not_contains "$output" "$RUNTIME_LEASE_ROOTS_DIR:"

  cleanup_runtime_lease
  [ ! -e "$lease_dir" ] || fail "expected foreground runtime lease cleanup"
)

test_remote_runtime_lease_persists_until_explicit_removal() (
  set -euo pipefail

  local tmp_dir lease_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  mkdir -p "$tmp_dir/project"

  hash_short() {
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,16)}'
  }
  source "$REPO_ROOT/bin/lib/runtime_lease.sh"

  CACHE_DIR="$tmp_dir/cache"
  PROJECT_ROOT="$tmp_dir/project"
  AGENT_COMMAND="remote"
  REMOTE_NAME="test-remote"
  REMOTE_STATE_DIR="$CACHE_DIR/remote/$REMOTE_NAME"
  prepare_runtime_lease
  lease_dir="$RUNTIME_LEASE_DIR"

  cleanup_runtime_lease
  [ -d "$lease_dir" ] || fail "expected remote lease to survive launcher exit"
  remove_runtime_lease "$lease_dir"
  [ ! -e "$lease_dir" ] || fail "expected remote lease removal at remote teardown"
)

test_need_helper_lifetime_follows_runtime_lease() (
  set -euo pipefail

  local tmp_dir helper_pid=""
  tmp_dir="$(mktemp -d)"
  cleanup_need_helper_lifetime_test() {
    if [ -n "$helper_pid" ]; then
      kill "$helper_pid" 2>/dev/null || true
      wait "$helper_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp_dir"
  }
  trap cleanup_need_helper_lifetime_test EXIT

  source "$REPO_ROOT/bin/lib/runtime_lease.sh"
  source "$REPO_ROOT/bin/lib/need_helper.sh"
  perf_log() { :; }

  AGENT_BIN_DIR="$REPO_ROOT/bin"
  AGENT_NEED_HELPER=1
  unset AGENT_NEED_HELPER_TTL
  RUNTIME_LEASE_DIR="$tmp_dir/lease"
  RUNTIME_LEASE_ID="lease-test"
  RUNTIME_LEASE_ROOTS_DIR="$RUNTIME_LEASE_DIR/roots"
  RUNTIME_LEASE_RECEIPTS_DIR="$RUNTIME_LEASE_DIR/receipts"
  mkdir -p "$RUNTIME_LEASE_ROOTS_DIR" "$RUNTIME_LEASE_RECEIPTS_DIR"

  prepare_need_helper
  helper_pid="$(cat "$NEED_HELPER_PID_FILE")"
  need_helper_service_running || fail "expected need helper to be healthy after startup"
  [ -s "$NEED_HELPER_HEARTBEAT_FILE" ] || fail "expected need helper readiness heartbeat"

  sleep 2
  need_helper_service_running || fail "expected idle need helper to remain lease-scoped"

  kill "$helper_pid"
  wait "$helper_pid"
  helper_pid=""
  [ ! -e "$NEED_HELPER_HEARTBEAT_FILE" ] || fail "expected need helper shutdown to remove its heartbeat"
)

test_need_helper_startup_failure_is_fatal() (
  set -euo pipefail

  local tmp_dir output status
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  mkdir -p "$tmp_dir/bin" "$tmp_dir/lease/roots" "$tmp_dir/lease/receipts"
  cat > "$tmp_dir/bin/agent-nix-helper" <<'EOF'
#!/usr/bin/env bash
echo "synthetic startup failure" >&2
exit 23
EOF
  chmod +x "$tmp_dir/bin/agent-nix-helper"

  set +e
  output="$(
    (
      source "$REPO_ROOT/bin/lib/runtime_lease.sh"
      source "$REPO_ROOT/bin/lib/need_helper.sh"
      perf_log() { :; }

      AGENT_BIN_DIR="$tmp_dir/bin"
      AGENT_NEED_HELPER=1
      unset AGENT_NEED_HELPER_TTL
      RUNTIME_LEASE_DIR="$tmp_dir/lease"
      RUNTIME_LEASE_ID="lease-test"
      RUNTIME_LEASE_ROOTS_DIR="$RUNTIME_LEASE_DIR/roots"
      RUNTIME_LEASE_RECEIPTS_DIR="$RUNTIME_LEASE_DIR/receipts"
      prepare_need_helper
    ) 2>&1
  )"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected failed need helper startup to stop launch"
  assert_contains "$output" "need helper failed to become ready"
  assert_contains "$output" "synthetic startup failure"
)

test_need_helper_rejects_obsolete_ttl() (
  set -euo pipefail

  local output status
  set +e
  output="$(
    AGENT_NEED_HELPER_TTL=1 bash -c '
      source "$1"
      resolve_need_helper_mode
    ' bash "$REPO_ROOT/bin/lib/need_helper.sh" 2>&1
  )"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected obsolete need helper TTL to fail"
  assert_contains "$output" "AGENT_NEED_HELPER_TTL is no longer supported"
  assert_contains "$output" "lives until runtime lease teardown"
)

test_need_helper_materialization_creates_leased_receipt() (
  set -euo pipefail

  local tmp_dir bin_dir roots_dir receipts_dir root_base receipt_file store_path output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  bin_dir="$tmp_dir/bin"
  roots_dir="$tmp_dir/roots"
  receipts_dir="$tmp_dir/receipts"
  root_base="$roots_dir/need-test"
  receipt_file="$receipts_dir/need-test.json"
  store_path="$(readlink -f /bin/bash)"
  mkdir -p "$bin_dir" "$roots_dir" "$receipts_dir" "$tmp_dir/home"

  cat > "$bin_dir/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode=""
root_path=""
for arg in "$@"; do
  case "$arg" in
    build|path-info) mode="$arg" ;;
  esac
done
if [ "$mode" = "build" ]; then
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--out-link" ]; then
      root_path="$2"
      break
    fi
    shift
  done
  printf 'build-root=%s\n' "$root_path" >> "$FAKE_NIX_LOG"
  ln -sfn "$FAKE_STORE_PATH" "$root_path"
  printf '%s\n' "$FAKE_STORE_PATH"
  exit 0
fi
if [ "$mode" = "path-info" ]; then
  printf '{"%s":{"narHash":"sha256-test","narSize":1,"references":[]}}\n' "$FAKE_STORE_PATH"
  exit 0
fi
exit 1
EOF
  chmod +x "$bin_dir/nix"

  output="$(
    FAKE_NIX_LOG="$tmp_dir/nix.log" \
    FAKE_STORE_PATH="$store_path" \
    AGENT_HOST_HOME="$tmp_dir/home" \
    PATH="$bin_dir:/usr/bin:/bin" \
    bash "$REPO_ROOT/bin/agent-nix-helper" materialize \
      nixpkgs#bash "$root_base" "$receipt_file" \
      /run/agent-runtime-receipts/need-test.json lease-test
  )"

  assert_contains "$output" "lease_id=lease-test"
  assert_contains "$output" "receipt_path=/run/agent-runtime-receipts/need-test.json"
  assert_contains "$(cat "$tmp_dir/nix.log")" "build-root=$root_base"
  [ -L "$root_base" ] || fail "expected materialization root to survive helper exit"
  [ "$(stat -c '%a' "$receipt_file")" = "444" ] || fail "expected immutable receipt mode"
  jq -e \
    --arg store_path "$store_path" \
    '.lease_id == "lease-test" and .kind == "need-materialization" and .selected_out_path == $store_path and (.closure | length) == 1' \
    "$receipt_file" >/dev/null
)

test_need_rejects_cache_from_previous_lease() (
  set -euo pipefail

  local tmp_dir need_cache receipts_dir installable out_dir bin_dir output status
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  need_cache="$tmp_dir/need"
  receipts_dir="$tmp_dir/receipts"
  installable="nixpkgs#jq"
  out_dir="$tmp_dir/out"
  bin_dir="$out_dir/bin"
  mkdir -p "$bin_dir"
  : > "$bin_dir/jq"
  chmod +x "$bin_dir/jq"
  write_need_materialization_cache \
    "$need_cache" "$installable" "$out_dir" "$bin_dir" old-lease "$receipts_dir"

  set +e
  output="$(
    AGENT_NEED_CACHE_DIR="$need_cache" \
    AGENT_NEED_HELPER_DIR="$tmp_dir/missing-helper" \
    AGENT_RUNTIME_LEASE_ID="new-lease" \
    AGENT_RUNTIME_RECEIPTS_DIR="$receipts_dir" \
    PATH="/usr/bin:/bin" \
    bash "$REPO_ROOT/scripts/image/need.sh" materialize "$installable" 2>&1
  )"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected previous-lease cache to be rejected"
  assert_contains "$output" "unleased materialization is disabled"
)

test_need_inject_creates_lease_checking_launcher() (
  set -euo pipefail

  local tmp_dir need_cache receipts_dir tools_dir installable out_dir bin_dir launcher
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  need_cache="$tmp_dir/need"
  receipts_dir="$tmp_dir/receipts"
  tools_dir="$need_cache/projects/test/bin"
  installable="nixpkgs#jq"
  out_dir="$tmp_dir/out"
  bin_dir="$out_dir/bin"
  mkdir -p "$bin_dir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/jq"
  chmod +x "$bin_dir/jq"
  write_need_materialization_cache \
    "$need_cache" "$installable" "$out_dir" "$bin_dir" lease-test "$receipts_dir"

  AGENT_NEED_CACHE_DIR="$need_cache" \
  AGENT_NEED_TOOLS_DIR="$tools_dir" \
  AGENT_NEED_HELPER_DIR="$tmp_dir/missing-helper" \
  AGENT_RUNTIME_LEASE_ID="lease-test" \
  AGENT_RUNTIME_RECEIPTS_DIR="$receipts_dir" \
  PATH="/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/image/need.sh" inject "$installable" >/dev/null

  launcher="$tools_dir/jq"
  [ -f "$launcher" ] && [ ! -L "$launcher" ] || fail "expected injected command to be a launcher"
  assert_contains "$(cat "$launcher")" "exec /bin/need run nixpkgs#jq -- jq"
)

test_runtime_owned_env_override_is_rejected() (
  set -euo pipefail

  local output status
  set +e
  output="$(
    AGENT_EXTRA_ENV='AGENT_RUNTIME_LEASE_ID=forged' \
    bash -c '
      set -euo pipefail
      source "$1"
      split_csv_or_lines() { printf "%s\n" "$1"; }
      ARGS=()
      append_extra_env_args
    ' bash "$REPO_ROOT/bin/lib/container_runtime.sh" 2>&1
  )"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected runtime-owned env override to fail"
  assert_contains "$output" "AGENT_EXTRA_ENV cannot override runtime-owned variable: AGENT_RUNTIME_LEASE_ID"
)

test_need_helper_does_not_mount_nix_daemon_socket() (
  set -euo pipefail

  local tmp_dir output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  ARGS=()
  HOST_HOME="$tmp_dir"
  Z_SUFFIX=""
  NEED_HELPER_MODE="1"
  NEED_HELPER_BRIDGE_DIR=""
  CONTAINER_API_MODE="none"
  AGENT_ALLOW_NIX_DAEMON_SOCKET="0"
  unset SSH_AUTH_SOCK
  append_host_socket_args
  output="${ARGS[*]}"
  assert_not_contains "$output" "/nix/var/nix/daemon-socket/socket"

  ARGS=()
  AGENT_ALLOW_NIX_DAEMON_SOCKET="1"
  append_host_socket_args
  output="${ARGS[*]}"
  if [ -S /nix/var/nix/daemon-socket/socket ]; then
    assert_contains "$output" "/nix/var/nix/daemon-socket/socket:/nix/var/nix/daemon-socket/socket:rw"
  fi
)

test_need_run_allows_command_side_sandbox_sudo() (
  set -euo pipefail

  local tmp_dir need_cache installable out_dir bin_dir sudo_dir receipts_dir lease_id output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  need_cache="$tmp_dir/need"
  installable="nixpkgs#jq"
  out_dir="$tmp_dir/out"
  bin_dir="$out_dir/bin"
  sudo_dir="$tmp_dir/sandbox-bin"
  receipts_dir="$tmp_dir/receipts"
  lease_id="lease-test"
  mkdir -p "$bin_dir" "$sudo_dir"
  printf '#!/usr/bin/env bash\nprintf "fake-jq\\n"\n' > "$bin_dir/jq"
  printf '#!/usr/bin/env bash\nprintf "sandbox-sudo:%%s\\n" "$*"\n' > "$sudo_dir/sudo"
  chmod +x "$bin_dir/jq" "$sudo_dir/sudo"

  write_need_materialization_cache "$need_cache" "$installable" "$out_dir" "$bin_dir" "$lease_id" "$receipts_dir"

  output="$(
    AGENT_NEED_CACHE_DIR="$need_cache" \
    AGENT_NEED_HELPER_DIR="$tmp_dir/missing-helper" \
    AGENT_RUNTIME_LEASE_ID="$lease_id" \
    AGENT_RUNTIME_RECEIPTS_DIR="$receipts_dir" \
    PATH="$sudo_dir:/usr/bin:/bin" \
    bash "$REPO_ROOT/scripts/image/need.sh" run "$installable" -- sudo id
  )"

  assert_contains "$output" "sandbox-sudo:id"
)

test_need_run_refuses_materialized_sudo_shadow() (
  set -euo pipefail

  local tmp_dir need_cache installable out_dir bin_dir receipts_dir lease_id output status
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  need_cache="$tmp_dir/need"
  installable="nixpkgs#sudo"
  out_dir="$tmp_dir/out"
  bin_dir="$out_dir/bin"
  receipts_dir="$tmp_dir/receipts"
  lease_id="lease-test"
  mkdir -p "$bin_dir"
  printf '#!/usr/bin/env bash\nprintf "unsafe-sudo\\n"\n' > "$bin_dir/sudo"
  chmod +x "$bin_dir/sudo"

  write_need_materialization_cache "$need_cache" "$installable" "$out_dir" "$bin_dir" "$lease_id" "$receipts_dir"

  set +e
  output="$(
    AGENT_NEED_CACHE_DIR="$need_cache" \
    AGENT_NEED_HELPER_DIR="$tmp_dir/missing-helper" \
    AGENT_RUNTIME_LEASE_ID="$lease_id" \
    AGENT_RUNTIME_RECEIPTS_DIR="$receipts_dir" \
    AGENT_ALLOW_SUDO=0 \
    PATH="/usr/bin:/bin" \
    bash "$REPO_ROOT/scripts/image/need.sh" run "$installable" -- sh -c 'sudo id' 2>&1
  )"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected need run to reject a sudo-providing bin path"
  assert_contains "$output" "refusing to inject privileged command 'sudo'"
  assert_contains "$output" "enable AGENT_ALLOW_SUDO=1"
)

test_container_api_does_not_kill_stale_reused_pid() (
  set -euo pipefail

  local output
  output="$(container_api_stale_pid_cleanup_for)"

  assert_contains "$output" "running=0"
  assert_contains "$output" "pid_exists=0"
  assert_contains "$output" "socket_exists=0"
  assert_contains "$output" "kill_log=empty"
)

test_need_clear_commands() (
  set -euo pipefail

  local tmp_dir need_cache tools_dir output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  need_cache="$tmp_dir/need"
  tools_dir="$need_cache/projects/project-a/bin"
  mkdir -p "$tools_dir" "$need_cache/bin" "$need_cache/materialized"
  : > "$tools_dir/pnpm"
  : > "$need_cache/bin/node"
  : > "$need_cache/materialized/item.env"

  output="$(AGENT_NEED_CACHE_DIR="$need_cache" AGENT_NEED_TOOLS_DIR="$tools_dir" bash "$REPO_ROOT/scripts/image/need.sh" clear 2>&1)"
  assert_contains "$output" "cleared injected executables from $tools_dir"
  [ ! -e "$tools_dir" ] || fail "expected scoped injected bins to be removed"
  [ -e "$need_cache/bin/node" ] || fail "expected legacy injected bins to remain after scoped clear"
  [ -e "$need_cache/materialized/item.env" ] || fail "expected materialization cache to remain after scoped clear"

  output="$(AGENT_NEED_CACHE_DIR="$need_cache" AGENT_NEED_TOOLS_DIR="$tools_dir" bash "$REPO_ROOT/scripts/image/need.sh" clear --legacy 2>&1)"
  assert_contains "$output" "cleared legacy injected executables from $need_cache/bin"
  [ ! -e "$need_cache/bin" ] || fail "expected legacy injected bins to be removed"
  [ -e "$need_cache/materialized/item.env" ] || fail "expected materialization cache to remain after legacy clear"

  output="$(AGENT_NEED_CACHE_DIR="$need_cache" AGENT_NEED_TOOLS_DIR="$tools_dir" bash "$REPO_ROOT/scripts/image/need.sh" clear --all 2>&1)"
  assert_contains "$output" "cleared need cache at $need_cache"
  [ ! -e "$need_cache" ] || fail "expected full need cache to be removed"
)

codex_mount_args_for() (
  set -euo pipefail

  local workspace_path="$1"
  local config_root="$2"
  local auth_base="${3:-}"
  local auth_selector="${4:-}"

  split_csv_or_lines() {
    local value="$1"
    printf '%s
' "$value" | tr ',' '
' | sed '/^[[:space:]]*$/d'
  }

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  HELPER_TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$HELPER_TMPDIR"' EXIT

  HOST_HOME="$workspace_path"
  WORKSPACE_PATH="$workspace_path"
  CODEX_CONFIG_MODE=host
  CODEX_HOST_CONFIG="$config_root"
  CODEX_AUTH_BASE="$auth_base"
  if [ -n "$auth_selector" ]; then
    CODEX_AUTH="$auth_selector"
  else
    unset CODEX_AUTH
  fi
  Z_SUFFIX=""
  ARGS=()
  mount_standard_engine codex

  printf '%s
' "${ARGS[@]}"
)

codex_project_mount_args_for() (
  set -euo pipefail

  local workspace_path="$1"
  local cache_dir="$2"
  local host_home="${3:-$workspace_path}"

  split_csv_or_lines() {
    local value="$1"
    printf '%s
' "$value" | tr ',' '
' | sed '/^[[:space:]]*$/d'
  }

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  HELPER_TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$HELPER_TMPDIR"' EXIT

  HOST_HOME="$host_home"
  PROJECT_ROOT="$workspace_path"
  WORKSPACE_PATH="$workspace_path"
  CACHE_DIR="$cache_dir"
  CODEX_CONFIG=project
  CODEX_AUTH_BASE="$cache_dir/auth"
  unset CODEX_AUTH
  Z_SUFFIX=""
  ARGS=()

  resolve_tool_config_roots
  printf 'config_root=%s
' "$CODEX_HOST_CONFIG"
  mount_standard_engine codex

  printf '%s
' "${ARGS[@]}"
)

test_codex_config_mount_omits_workspace_alias() (
  set -euo pipefail

  local tmp_dir workspace config_root output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  config_root="$tmp_dir/codex-home"
  mkdir -p "$workspace" "$config_root"

  output="$(codex_mount_args_for "$workspace" "$config_root")"

  assert_contains "$output" "$config_root:/cache/.codex:rw"
  assert_not_contains "$output" "/cache/.codex/config.toml:ro"
  assert_not_contains "$output" "$config_root:$workspace/.codex:rw"
  assert_contains "$(cat "$config_root/config.toml")" 'mcp_oauth_credentials_store = "file"'
  [ -w "$config_root/config.toml" ] || fail "expected generated Codex config to be writable"
  printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$workspace" >> "$config_root/config.toml"
  assert_contains "$(cat "$config_root/config.toml")" 'trust_level = "trusted"'
  [ ! -e "$workspace/.codex" ] || fail "expected codex workspace alias target to be absent"
)


test_codex_project_config_mount_uses_stable_runtime_home() (
  set -euo pipefail

  local tmp_dir workspace cache_dir output config_root
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  cache_dir="$tmp_dir/cache"
  mkdir -p "$workspace" "$cache_dir"

  output="$(codex_project_mount_args_for "$workspace" "$cache_dir")"
  config_root="$(printf '%s
' "$output" | awk -F= '/^config_root=/{print $2; exit}')"

  assert_contains "$output" "config_root=$workspace/.codex"
  assert_contains "$output" "CODEX_HOME=/cache/.codex"
  assert_contains "$output" "AGENT_CODEX_ROLLOUT_SOURCE_HOME=$workspace/.codex"
  assert_contains "$output" "$workspace/.codex:/cache/.codex:rw"
  assert_contains "$output" "$workspace/.agent-sandbox/codex:/etc/codex:ro"
  [ -d "$config_root/sessions" ] || mkdir -p "$config_root/sessions"
  [ -d "$config_root" ] || fail "expected project-local Codex home to be created"
  [ -f "$config_root/config.toml" ] || fail "expected writable Codex runtime config mountpoint"
  [ -f "$workspace/.agent-sandbox/codex/managed_config.toml" ] || fail "expected project managed config to be created"
)

test_codex_rollout_path_migration_rewrites_state_db() (
  set -euo pipefail

  local tmp_dir source_home codex_home state_db output rows
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  source_home="$tmp_dir/source %_ home"
  codex_home="$tmp_dir/canonical home"
  state_db="$codex_home/state_5.sqlite"
  mkdir -p "$source_home" "$codex_home"

  CODEX_TEST_DB="$state_db" \
    CODEX_TEST_SOURCE_HOME="$source_home" \
    bun --eval '
      import { Database } from "bun:sqlite";
      const db = new Database(process.env.CODEX_TEST_DB);
      db.run("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL)");
      const insert = db.query("INSERT INTO threads (id, rollout_path) VALUES (?1, ?2)");
      insert.run("active", `${process.env.CODEX_TEST_SOURCE_HOME}/sessions/2026/08/21/active.jsonl`);
      insert.run("archived", `${process.env.CODEX_TEST_SOURCE_HOME}/archived_sessions/archived.jsonl`);
      insert.run("external", "/other/codex/sessions/external.jsonl");
      db.close(true);
    '

  output="$(
    AGENT_CODEX_ROLLOUT_SOURCE_HOME="$source_home" \
      CODEX_HOME="$codex_home" \
      bun "$REPO_ROOT/scripts/image/codex-state-migrate.ts" 2>&1
  )"
  assert_contains "$output" "migrated 2 Codex rollout paths from $source_home to $codex_home"

  rows="$(
    CODEX_TEST_DB="$state_db" bun --eval '
      import { Database } from "bun:sqlite";
      const db = new Database(process.env.CODEX_TEST_DB, { readonly: true });
      console.log(JSON.stringify(db.query("SELECT id, rollout_path FROM threads ORDER BY id").all()));
      db.close(true);
    '
  )"
  assert_contains "$rows" "$codex_home/sessions/2026/08/21/active.jsonl"
  assert_contains "$rows" "$codex_home/archived_sessions/archived.jsonl"
  assert_contains "$rows" '"/other/codex/sessions/external.jsonl"'
  assert_not_contains "$rows" "$source_home/sessions"

  output="$(
    AGENT_CODEX_ROLLOUT_SOURCE_HOME="$source_home" \
      CODEX_HOME="$codex_home" \
      bun "$REPO_ROOT/scripts/image/codex-state-migrate.ts" 2>&1
  )"
  [ -z "$output" ] || fail "expected an idempotent Codex rollout path migration"
)

test_codex_project_managed_config_is_seeded_from_host() (
  set -euo pipefail

  local tmp_dir workspace host_home cache_dir output managed_config runtime_config
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  host_home="$tmp_dir/host"
  cache_dir="$tmp_dir/cache"
  mkdir -p "$workspace" "$host_home/.codex" "$cache_dir"
  printf 'model = "host-model"\n' > "$host_home/.codex/config.toml"

  output="$(codex_project_mount_args_for "$workspace" "$cache_dir" "$host_home")"
  managed_config="$(cat "$workspace/.agent-sandbox/codex/managed_config.toml")"
  runtime_config="$(cat "$workspace/.codex/config.toml")"

  assert_contains "$output" "$workspace/.agent-sandbox/codex:/etc/codex:ro"
  assert_contains "$managed_config" 'mcp_oauth_credentials_store = "file"'
  assert_contains "$managed_config" 'model = "host-model"'
  assert_contains "$runtime_config" 'mcp_oauth_credentials_store = "file"'
  assert_not_contains "$runtime_config" 'model = "host-model"'
)

test_codex_project_state_migrates_cache_sessions_without_clobbering() (
  set -euo pipefail

  local tmp_dir workspace cache_dir scope_key legacy_root output marker
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  cache_dir="$tmp_dir/cache"
  scope_key="$(printf '%s' "$workspace" | sha256sum | awk '{print substr($1,1,16)}')"
  legacy_root="$cache_dir/project-config/codex/$scope_key"
  marker="$workspace/.agent-sandbox/codex/cache-state-migration-v1"
  mkdir -p "$workspace/.codex/sessions/2026/01/01" "$legacy_root/sessions/2026/01/01" "$legacy_root/archived_sessions"
  printf 'project-copy\n' > "$workspace/.codex/sessions/2026/01/01/existing.jsonl"
  printf 'cache-copy\n' > "$legacy_root/sessions/2026/01/01/existing.jsonl"
  printf 'new-session\n' > "$legacy_root/sessions/2026/01/01/new.jsonl"
  printf 'archived\n' > "$legacy_root/archived_sessions/archived.jsonl"
  printf 'history\n' > "$legacy_root/history.jsonl"
  printf 'sqlite\n' > "$legacy_root/state_5.sqlite"
  printf 'model = "cache-model"\n' > "$legacy_root/config.toml"

  output="$(codex_project_mount_args_for "$workspace" "$cache_dir" 2>&1)"

  assert_contains "$output" "migrated 4 Codex state files into $workspace/.codex"
  assert_contains "$(cat "$workspace/.codex/sessions/2026/01/01/existing.jsonl")" 'project-copy'
  assert_contains "$(cat "$workspace/.codex/sessions/2026/01/01/new.jsonl")" 'new-session'
  assert_contains "$(cat "$workspace/.codex/archived_sessions/archived.jsonl")" 'archived'
  assert_contains "$(cat "$workspace/.codex/history.jsonl")" 'history'
  assert_contains "$(cat "$workspace/.codex/state_5.sqlite")" 'sqlite'
  assert_contains "$(cat "$workspace/.agent-sandbox/codex/managed_config.toml")" 'model = "cache-model"'
  assert_contains "$(cat "$marker")" "$legacy_root"
  [ -f "$legacy_root/sessions/2026/01/01/new.jsonl" ] || fail "expected legacy cache state to remain available for recovery"

  output="$(codex_project_mount_args_for "$workspace" "$cache_dir" 2>&1)"
  assert_not_contains "$output" "migrated "
)

test_codex_project_home_rejects_symlink() (
  set -euo pipefail

  local tmp_dir workspace cache_dir output status
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  cache_dir="$tmp_dir/cache"
  mkdir -p "$workspace" "$cache_dir" "$tmp_dir/shared-codex"
  ln -s "$tmp_dir/shared-codex" "$workspace/.codex"

  set +e
  output="$(codex_project_mount_args_for "$workspace" "$cache_dir" 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected symlinked project Codex home to fail"
  assert_contains "$output" "project Codex home must be a real directory, not a symlink: $workspace/.codex"
)

test_codex_config_mount_handles_explicit_workspace_config_root() (
  set -euo pipefail

  local tmp_dir workspace output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  mkdir -p "$workspace/.codex"

  output="$(codex_mount_args_for "$workspace" "$workspace/.codex")"

  assert_contains "$output" "$workspace/.codex:/cache/.codex:rw"
  assert_not_contains "$output" "$workspace/.codex:$workspace/.codex:rw"
)

test_codex_config_mount_ignores_workspace_symlink_alias() (
  set -euo pipefail

  local tmp_dir workspace config_root shared_config output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  config_root="$tmp_dir/codex-home"
  shared_config="$tmp_dir/.codex"
  mkdir -p "$workspace" "$config_root" "$shared_config"
  ln -s ../.codex "$workspace/.codex"

  output="$(codex_mount_args_for "$workspace" "$config_root")"

  assert_contains "$output" "$config_root:/cache/.codex:rw"
  assert_not_contains "$output" "$config_root:$shared_config:rw"
  assert_not_contains "$output" "$config_root:$workspace/.codex:rw"
)

test_codex_config_dir_requires_write_access() (
  set -euo pipefail

  local tmp_dir workspace config_root output status
  tmp_dir="$(mktemp -d)"
  trap 'chmod u+rwx "$config_root" 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  config_root="$tmp_dir/codex-home"
  mkdir -p "$workspace" "$config_root"
  chmod a-w "$config_root"

  set +e
  output="$(codex_mount_args_for "$workspace" "$config_root" 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected unreadable config dir to fail"
  assert_contains "$output" "config directory for codex must be readable, writable, and searchable: $config_root"
)

test_codex_config_file_requires_write_access() (
  set -euo pipefail

  local tmp_dir workspace config_root config_file output status
  tmp_dir="$(mktemp -d)"
  trap 'chmod u+rw "$config_file" 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  config_root="$tmp_dir/codex-home"
  config_file="$config_root/config.toml"
  mkdir -p "$workspace" "$config_root"
  : > "$config_file"
  chmod a-w "$config_file"

  set +e
  output="$(codex_mount_args_for "$workspace" "$config_root" 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected read-only Codex config file to fail"
  assert_contains "$output" "config file for codex must be readable and writable: $config_file"
)

test_codex_api_key_config_remains_writable() (
  set -euo pipefail

  local tmp_dir workspace config_root output config
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  config_root="$tmp_dir/codex-home"
  mkdir -p "$workspace" "$config_root"

  output="$(OPENAI_API_KEY=test-key OPENAI_BASE_URL=https://example.invalid/v1 codex_mount_args_for "$workspace" "$config_root")"
  config="$(cat "$config_root/config.toml")"

  assert_not_contains "$output" "/cache/.codex/config.toml:ro"
  assert_contains "$config" 'mcp_oauth_credentials_store = "file"'
  assert_contains "$config" 'openai_base_url = "https://example.invalid/v1"'
  [ -w "$config_root/config.toml" ] || fail "expected API-key Codex config to remain writable"
)

test_codex_auth_file_requires_read_access() (
  set -euo pipefail

  local tmp_dir workspace config_root auth_base auth_file output status
  tmp_dir="$(mktemp -d)"
  trap 'chmod u+rw "$auth_file" 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  config_root="$tmp_dir/codex-home"
  auth_base="$tmp_dir/auth"
  auth_file="$auth_base/work.json"
  mkdir -p "$workspace" "$config_root" "$auth_base"
  : > "$auth_file"
  chmod a-r "$auth_file"

  set +e
  output="$(codex_mount_args_for "$workspace" "$config_root" "$auth_base" work 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected unreadable auth file to fail"
  assert_contains "$output" "auth selector 'work' for codex did not resolve to a readable file: $auth_file"
)

test_image_includes_openssh() (
  set -euo pipefail

  local image_file artifact_file rootfs_file
  image_file="$(cat "$REPO_ROOT/nix/image.nix")"
  artifact_file="$(cat "$REPO_ROOT/bin/lib/artifact_prep.sh")"
  rootfs_file="$(cat "$REPO_ROOT/bin/lib/rootfs.sh")"

  assert_contains "$image_file" "pkgs.openssh"
  assert_contains "$image_file" "pkgs.tmux"
  assert_contains "$image_file" "remoteScripts"
  assert_contains "$image_file" "agent-remote-entrypoint"
  assert_contains "$image_file" "agent-remote-dispatch"
  assert_contains "$image_file" "agent-remote-shell"
  assert_contains "$image_file" "agent-remote-codex"
  assert_contains "$image_file" "firecrackerPodmanWrapper"
  assert_contains "$image_file" "agent-firecracker-podman"
  assert_contains "$image_file" 'podman_state=/cache/agent-firecracker-podman'
  assert_contains "$image_file" 'env TMPDIR="$podman_tmpdir"'
  assert_contains "$image_file" '--storage-driver vfs'
  assert_contains "$image_file" '--root "$podman_root"'
  assert_contains "$image_file" '--runroot "$podman_runroot"'
  assert_contains "$image_file" '--network-config-dir "$podman_network_config"'
  assert_contains "$image_file" 'chmod 1777 "$podman_tmpdir"'
  assert_contains "$image_file" "containersPolicy"
  assert_contains "$image_file" 'etc/containers/policy.json'
  assert_contains "$image_file" 'chmod 1777 "$out/tmp" "$out/var/tmp"'
  assert_contains "$image_file" "pkgs.iproute2"
  assert_contains "$image_file" "sudoPackage = pkgs.sudo.overrideAttrs"
  assert_contains "$image_file" '"--without-pam"'
  assert_contains "$image_file" "sudoConfig"
  assert_contains "$image_file" "sudoRuntime"
  assert_contains "$image_file" 'agent-sudo-package'
  assert_contains "$image_file" "ALL ALL=(ALL:ALL) NOPASSWD:SETENV: ALL"
  assert_contains "$image_file" "sudoImagePerms"
  assert_contains "$image_file" 'regex = "agent-sudo/bin/sudo$"'
  assert_contains "$image_file" 'regex = "agent-sudo/bin/sudoedit$"'
  assert_contains "$image_file" 'mode = "4755"'
  assert_contains "$image_file" 'rm -rf "$out/agent-sudo"'
  assert_contains "$image_file" 'install -Dm0755 -T "${sudoRuntime}/agent-sudo/bin/sudo" "$out/agent-sudo/bin/sudo"'
  assert_contains "$image_file" 'install -Dm0755 -T "${sudoRuntime}/agent-sudo/bin/sudoedit" "$out/agent-sudo/bin/sudoedit"'
  assert_contains "$image_file" 'install -Dm0440 -T "${sudoConfig}/etc/sudoers.d/agent-sandbox" "$out/etc/sudoers"'
  assert_not_contains "$image_file" '      sudoPackage'
  assert_not_contains "$image_file" '"PATH=/agent-sudo/bin:'
  assert_contains "$image_file" '"$out/run/host-services"'
  assert_contains "$image_file" '"$out/run/agent-path-guard"'
  assert_contains "$image_file" '"$out/proc" "$out/sys/fs/cgroup" "$out/dev/net"'
  assert_contains "$image_file" "proc sys sys/fs sys/fs/cgroup dev dev/net"
  assert_contains "$image_file" "var/tmp"
  assert_contains "$rootfs_file" "ROOTFS_MIRROR_FORMAT=7"
  assert_contains "$rootfs_file" "run/agent-path-guard"
  assert_contains "$rootfs_file" "run/agent-runtime-receipts"
  assert_contains "$rootfs_file" "var/tmp"
  assert_contains "$rootfs_file" "sys/fs/cgroup"
  assert_contains "$rootfs_file" "dev/net"
  assert_contains "$artifact_file" "prepare_rootfs_artifact"
  assert_contains "$artifact_file" '--out-link "$gcroot_path"'
  assert_not_contains "$artifact_file" 'tmp_root="${gcroot_path}.tmp.$$"'
  assert_contains "$artifact_file" "copyToDockerDaemon"
  assert_not_contains "$artifact_file" "copyToPodman"
)

test_need_defaults_to_unstable_nixpkgs() (
  set -euo pipefail

  local need_file image_file compat_file
  need_file="$(cat "$REPO_ROOT/scripts/image/need.sh")"
  image_file="$(cat "$REPO_ROOT/nix/image.nix")"
  compat_file="$(cat "$REPO_ROOT/scripts/image/agent-compat.sh")"

  assert_contains "$need_file" 'DEFAULT_NIXPKGS_FLAKE_REF="github:NixOS/nixpkgs/nixos-unstable"'
  assert_contains "$need_file" 'resolved_installable="${DEFAULT_NIXPKGS_FLAKE_REF}#$best_attr"'
  assert_contains "$compat_file" 'default_nixpkgs_flake_ref="github:NixOS/nixpkgs/nixos-unstable"'
  assert_contains "$image_file" '"NIX_PATH=nixpkgs=${unstablePkgs.path}"'
)

run_test() {
  local name="$1"
  shift

  echo "[test] $name"
  "$@"
}

main() {
  run_test "opencode wrapper default" test_opencode_wrapper_default
  run_test "runtime resolution parity" test_runtime_resolution_parity
  run_test "runtime invocation exposes logical agent argv0" test_runtime_invocation_exposes_logical_agent_argv0
  run_test "host home fallbacks present" test_host_home_fallbacks_present
  run_test "stable fetchTarball uses lock" test_stable_fetchtarball_uses_lock
  run_test "mutable channel fetchTarball uses lock" test_mutable_channel_fetchtarball_uses_lock
  run_test "missing fetchTarball lock is created" test_missing_fetchtarball_lock_is_created
  run_test "shell.nix NIX_PATH default receives explicit pkgs" test_shell_nix_nix_path_default_receives_explicit_pkgs
  run_test "symlinked shell stages resolved nix contract" test_symlinked_shell_stages_resolved_nix_contract
  run_test "image uses standard git" test_image_uses_standard_git
  run_test "device passthrough support" test_device_passthrough_support
  run_test "kvm smoke script" test_kvm_smoke_script
  run_test "bun latest lookup uses tool cache" test_bun_latest_lookup_uses_tool_cache
  run_test "codex bubblewrap compat path" test_codex_bubblewrap_compat_path
  run_test "workspace mounts for regular repo override" test_workspace_mounts_for_regular_repo_workspace_override
  run_test "workspace mounts for linked worktree override" test_workspace_mounts_for_linked_worktree_workspace_override
  run_test "config selectors are not passthrough env" test_config_selectors_are_not_passthrough_env
  run_test "ssh agent mount support" test_ssh_agent_mount_support
  run_test "remote mode suppresses ssh agent by default" test_remote_mode_suppresses_ssh_agent_by_default
  run_test "remote secrets are not passthrough env" test_remote_secrets_are_not_passthrough_env
  run_test "remote host env opt-in restores agent passthrough" test_remote_host_env_opt_in_restores_agent_passthrough
  run_test "remote rejects broad bridges by default" test_remote_rejects_broad_bridges_by_default
  run_test "remote forces safe helper defaults" test_remote_forces_safe_helper_defaults
  run_test "remote defaults codex config to project" test_remote_defaults_codex_config_to_project
  run_test "remote light bootstrap skips firecracker confirmation" test_remote_light_bootstrap_skips_firecracker_confirmation
  run_test "remote requires tailscale auth before starting" test_remote_requires_tailscale_auth_before_starting
  run_test "remote up preflights auth before artifacts" test_remote_up_preflights_auth_before_artifacts
  run_test "remote pod has no published ports" test_remote_pod_has_no_published_ports
  run_test "remote tailscale sidecar uses userspace pod network" test_remote_tailscale_sidecar_uses_userspace_pod_network
  run_test "remote firecracker tailscale sidecar uses host network init" test_remote_firecracker_tailscale_sidecar_uses_host_network_init
  run_test "remote sessions text distinguishes live and transcripts" test_remote_sessions_text_distinguishes_live_and_transcripts
  run_test "remote codex noninteractive starts without attach" test_remote_codex_noninteractive_starts_without_attach
  run_test "ssh runtime generation" test_ssh_runtime_generation
  run_test "dev env path precedence" test_dev_env_path_precedence
  run_test "runtime path uses project-scoped need bins" test_runtime_path_uses_project_scoped_need_bins
  run_test "runtime path includes sudo when enabled" test_runtime_path_includes_sudo_when_enabled
  run_test "runtime modes preserve podman rootfs" test_runtime_modes_preserve_podman_rootfs
  run_test "firecracker profile rejects docker runtime" test_firecracker_profile_rejects_docker_runtime
  run_test "rootless linux profile rejects docker runtime" test_rootless_linux_profile_rejects_docker_runtime
  run_test "stream image helper uses docker helper attr" test_stream_image_helper_uses_docker_helper_attr
  run_test "runtime identity masks sudo by default" test_runtime_identity_masks_sudo_by_default
  run_test "runtime identity mounts sudo overlay when enabled" test_runtime_identity_mounts_sudo_overlay_when_enabled
  run_test "stdio target uses podman rootfs" test_stdio_target_uses_podman_rootfs
  run_test "rootless linux target uses private session entrypoint" test_rootless_linux_target_uses_private_session_entrypoint
  run_test "rootless linux runtime uses delegated user scope" test_rootless_linux_runtime_uses_delegated_user_scope
  run_test "runtime containers require PID 1 init" test_runtime_containers_require_pid1_init
  run_test "remote base container uses stable pod" test_remote_base_container_uses_stable_pod
  run_test "remote firecracker base container skips pod" test_remote_firecracker_base_container_skips_pod
  run_test "remote rootless linux profile is rejected" test_remote_rootless_linux_profile_is_rejected
  run_test "remote target uses entrypoint" test_remote_target_uses_entrypoint
  run_test "path guard excludes privileged sudo" test_path_guard_excludes_privileged_sudo
  run_test "firecracker path guard wraps podman" test_firecracker_path_guard_wraps_podman
  run_test "base container disables sudo by default" test_base_container_disables_sudo_by_default
  run_test "base container allows sudo when enabled" test_base_container_allows_sudo_when_enabled
  run_test "base container uses firecracker host profile" test_base_container_uses_firecracker_host_profile
  run_test "base container uses rootless linux profile" test_base_container_uses_rootless_linux_profile
  run_test "sudo flag rejects invalid values" test_sudo_flag_rejects_invalid_values
  run_test "firecracker profile requires sudo" test_firecracker_profile_requires_sudo
  run_test "rootless linux profile rejects sudo" test_rootless_linux_profile_rejects_sudo
  run_test "firecracker runtime identity uses rootful sudo overlay" test_firecracker_runtime_identity_uses_rootful_sudo_overlay
  run_test "firecracker runtime identity args use host namespaces" test_firecracker_runtime_identity_args_use_host_namespaces
  run_test "firecracker host devices and cgroup mount" test_firecracker_host_devices_and_cgroup_mount
  run_test "firecracker preflight accepts capable host" test_firecracker_preflight_accepts_capable_host
  run_test "firecracker preflight rejects rootless podman" test_firecracker_preflight_rejects_rootless_podman
  run_test "firecracker preflight rejects sudoed launcher" test_firecracker_preflight_rejects_sudoed_launcher
  run_test "firecracker preflight rejects missing cgroup v2" test_firecracker_preflight_rejects_missing_cgroup_v2
  run_test "firecracker preflight rejects cgroup control write failure" test_firecracker_preflight_rejects_cgroup_control_write_failure
  run_test "firecracker preflight rejects missing kvm" test_firecracker_preflight_rejects_missing_kvm
  run_test "firecracker preflight rejects missing tun" test_firecracker_preflight_rejects_missing_tun
  run_test "firecracker preflight rejects root workspace failure" test_firecracker_preflight_rejects_root_workspace_failure
  run_test "rootless linux preflight accepts capable host" test_rootless_linux_preflight_accepts_capable_host
  run_test "rootless linux preflight rejects missing user manager" test_rootless_linux_preflight_rejects_missing_user_manager
  run_test "rootless linux preflight rejects incomplete delegation" test_rootless_linux_preflight_rejects_incomplete_delegation
  run_test "rootless linux preflight rejects missing user namespaces" test_rootless_linux_preflight_rejects_missing_user_namespaces
  run_test "rootless linux preflight rejects rootful podman" test_rootless_linux_preflight_rejects_rootful_podman
  run_test "rootless linux session contract" test_rootless_linux_session_contract
  run_test "host GC roots use final paths" test_host_gc_root_registration_uses_final_path
  run_test "runtime lease retains artifact and mounts receipts" test_runtime_lease_retains_artifact_and_mounts_receipts
  run_test "remote runtime lease persists until removal" test_remote_runtime_lease_persists_until_explicit_removal
  run_test "need helper lifetime follows runtime lease" test_need_helper_lifetime_follows_runtime_lease
  run_test "need helper startup failure is fatal" test_need_helper_startup_failure_is_fatal
  run_test "need helper rejects obsolete TTL" test_need_helper_rejects_obsolete_ttl
  run_test "need helper creates leased receipt" test_need_helper_materialization_creates_leased_receipt
  run_test "need rejects previous lease cache" test_need_rejects_cache_from_previous_lease
  run_test "need inject creates lease-checking launcher" test_need_inject_creates_lease_checking_launcher
  run_test "runtime-owned env overrides are rejected" test_runtime_owned_env_override_is_rejected
  run_test "need helper does not mount Nix daemon socket" test_need_helper_does_not_mount_nix_daemon_socket
  run_test "need run allows command-side sandbox sudo" test_need_run_allows_command_side_sandbox_sudo
  run_test "need run refuses materialized sudo shadow" test_need_run_refuses_materialized_sudo_shadow
  run_test "podman session ignores stale reused pid" test_container_api_does_not_kill_stale_reused_pid
  run_test "need clear commands" test_need_clear_commands
  run_test "codex config mount omits workspace alias" test_codex_config_mount_omits_workspace_alias
  run_test "codex project config mount uses stable runtime home" test_codex_project_config_mount_uses_stable_runtime_home
  run_test "codex rollout path migration rewrites state db" test_codex_rollout_path_migration_rewrites_state_db
  run_test "codex project managed config is seeded from host" test_codex_project_managed_config_is_seeded_from_host
  run_test "codex project state migrates cache sessions without clobbering" test_codex_project_state_migrates_cache_sessions_without_clobbering
  run_test "codex project home rejects symlink" test_codex_project_home_rejects_symlink
  run_test "codex config mount handles explicit workspace config root" test_codex_config_mount_handles_explicit_workspace_config_root
  run_test "codex config mount ignores workspace symlink alias" test_codex_config_mount_ignores_workspace_symlink_alias
  run_test "codex config dir requires write access" test_codex_config_dir_requires_write_access
  run_test "codex config file requires write access" test_codex_config_file_requires_write_access
  run_test "codex API key config remains writable" test_codex_api_key_config_remains_writable
  run_test "codex auth file requires read access" test_codex_auth_file_requires_read_access
  run_test "image includes openssh" test_image_includes_openssh
  run_test "need defaults to unstable nixpkgs" test_need_defaults_to_unstable_nixpkgs

  if [ "${AGENT_RUN_KVM_TESTS:-0}" = "1" ]; then
    run_test "microvm smoke" "$REPO_ROOT/tests/kvm-smoke.sh"
  fi
  if [ "${AGENT_RUN_PID1_REAPER_TESTS:-0}" = "1" ]; then
    run_test "PID 1 orphan reaping smoke" "$REPO_ROOT/tests/runtime-init-smoke.sh"
  fi
  if [ "${AGENT_RUN_ROOTLESS_LINUX_TESTS:-0}" = "1" ]; then
    run_test "rootless Linux delegated session smoke" "$REPO_ROOT/tests/rootless-linux-smoke.sh"
  fi
}

main "$@"
