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
  local cache_key cache_file

  cache_key="$(printf '%s' "$installable" | sha256sum | awk '{print $1}')"
  cache_file="$need_cache/materialized/$cache_key.env"
  mkdir -p "$(dirname "$cache_file")"
  {
    printf 'status=ok\n'
    printf 'installable=%s\n' "$installable"
    printf 'out_path=%s\n' "$out_path"
    printf 'bin_path=%s\n' "$bin_path"
  } > "$cache_file"
}

pin_shell_fetchtarball_for() (
  set -euo pipefail

  local url="$1"
  local cached_hash="$2"
  local fresh_hash="$3"
  local tmp_dir target_dir bin_dir cache_key cache_file output calls

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  target_dir="$tmp_dir/project"
  bin_dir="$tmp_dir/bin"
  mkdir -p "$target_dir" "$bin_dir" "$tmp_dir/home/.cache/agent-sandbox"

  printf '{ pkgs ? import (fetchTarball "%s") {} }: pkgs.mkShell { packages = []; }\n' "$url" > "$target_dir/shell.nix"

  cache_key="$(printf '%s' "$url" | sha256sum | awk '{print $1}')"
  cache_file="$tmp_dir/home/.cache/agent-sandbox/pinned-nixpkgs-${cache_key}.json"
  if [ -n "$cached_hash" ]; then
    printf '{"url":"%s","sha256":"%s"}\n' "$url" "$cached_hash" > "$cache_file"
  fi

  cat > "$bin_dir/nix-prefetch-url" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'called %s\n' "\$*" >> "$tmp_dir/prefetch.log"
printf '%s\n' "$fresh_hash"
EOF
  chmod +x "$bin_dir/nix-prefetch-url"

  source "$REPO_ROOT/bin/lib/project_contract.sh"
  output="$(HOME="$tmp_dir/home" PATH="$bin_dir:/usr/bin:/bin" pin_shell_fetchtarball "$target_dir" 2>&1)"

  if [ -f "$tmp_dir/prefetch.log" ]; then
    calls="$(wc -l < "$tmp_dir/prefetch.log")"
  else
    calls="0"
  fi

  printf 'output=%s\n' "$output"
  printf 'pinned=%s\n' "$(cat "$target_dir/.agent-sandbox-pinned-nixpkgs.json")"
  printf 'calls=%s\n' "$calls"
  if [ -f "$cache_file" ]; then
    printf 'cache=%s\n' "$(cat "$cache_file")"
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

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  PATH_GUARD_CONTAINER_DIR="/run/agent-path-guard"
  SUDO_RUNTIME_PATH="/agent-sudo/bin"
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

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  PATH_GUARD_CONTAINER_DIR="/run/agent-path-guard"
  SUDO_RUNTIME_PATH="/agent-sudo/bin"
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

  source "$REPO_ROOT/bin/lib/artifact_prep.sh"

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

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  HELPER_TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$HELPER_TMPDIR" "$PATH_GUARD_HOST_DIR"' EXIT

  prepare_path_guard_dir

  find "$PATH_GUARD_HOST_DIR" -maxdepth 1 -type l -printf '%f -> %l\n' | LC_ALL=C sort
)

base_container_args_for() (
  set -euo pipefail

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

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

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  mkdir -p "$tmp_dir/rootfs/agent-sudo/bin" "$tmp_dir/helper"
  printf '#!/bin/sh\n' > "$tmp_dir/rootfs/agent-sudo/bin/sudo"
  chmod 0755 "$tmp_dir/rootfs/agent-sudo/bin/sudo"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

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
  printf 'sudoers:\n%s\n' "$(cat "$RUNTIME_IDENTITY_HOST_DIR/sudoers")"
  printf 'sudo_mode=%s\n' "$(stat -c '%a' "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo/bin/sudo")"
  printf 'sudoedit_mode=%s\n' "$(stat -c '%a' "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo/bin/sudoedit")"
  cat "$tmp_dir/podman.log"
)

stdio_target_args_for() (
  set -euo pipefail

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

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

  doctor_output="$(cd "$REPO_ROOT" && AGENT_RUNTIME="$bad_runtime" ./scripts/agent doctor 2>&1)"
  assert_contains "$doctor_output" "requested runtime '$bad_runtime' is not available"

  set +e
  run_output="$(cd "$REPO_ROOT" && AGENT_RUNTIME="$bad_runtime" ./scripts/agent codex 2>&1)"
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

test_stable_fetchtarball_uses_cached_pin() (
  set -euo pipefail

  local output
  output="$(pin_shell_fetchtarball_for "https://example.com/nixpkgs-abc123.tar.gz" "cachedhash" "freshhash")"

  assert_contains "$output" "pinned={\"url\":\"https://example.com/nixpkgs-abc123.tar.gz\",\"sha256\":\"cachedhash\"}"
  assert_contains "$output" "cache={\"url\":\"https://example.com/nixpkgs-abc123.tar.gz\",\"sha256\":\"cachedhash\"}"
  assert_contains "$output" "calls=0"
  assert_contains "$output" "(cached)"
)

test_mutable_channel_fetchtarball_refreshes_stale_pin() (
  set -euo pipefail

  local output
  output="$(pin_shell_fetchtarball_for "https://nixos.org/channels/nixpkgs-unstable/nixexprs.tar.xz" "stalehash" "freshhash")"

  assert_contains "$output" "pinned={\"url\":\"https://nixos.org/channels/nixpkgs-unstable/nixexprs.tar.xz\",\"sha256\":\"freshhash\"}"
  assert_contains "$output" "cache={\"url\":\"https://nixos.org/channels/nixpkgs-unstable/nixexprs.tar.xz\",\"sha256\":\"stalehash\"}"
  assert_contains "$output" "calls=1"
  assert_contains "$output" "refreshed mutable URL"
  assert_not_contains "$output" "(cached)"
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

test_git_wrapper_policy() (
  set -euo pipefail

  local image_file
  image_file="$(cat "$REPO_ROOT/nix/image.nix")"

  assert_contains "$image_file" 'SAFE_COMMANDS="clone|status|diff|log|show|ls-files|rev-parse|describe|ls-tree|cat-file|blame|grep|reflog|for-each-ref|rev-list|shortlog|symbolic-ref|name-rev|merge-base"'
  assert_not_contains "$image_file" 'clone|fetch'
  assert_not_contains "$image_file" '|branch|'
  assert_not_contains "$image_file" '|config|'
  assert_not_contains "$image_file" '|remote|'
  assert_not_contains "$image_file" '|tag|'
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

  assert_contains "$image_file" 'latest_version="$((cd "$CACHE_DIR" && ${pkgs.bun}/bin/bun info ${pkg} version) 2>/dev/null | head -n1 || true)"'
)

test_codex_bubblewrap_compat_path() (
  set -euo pipefail

  local image_file readme_file
  image_file="$(cat "$REPO_ROOT/nix/image.nix")"
  readme_file="$(cat "$REPO_ROOT/README.md")"

  assert_contains "$image_file" 'bubblewrapCompat = pkgs.runCommand "bubblewrap-compat"'
  assert_contains "$image_file" 'ln -s ${pkgs.bubblewrap}/bin/bwrap "$out/usr/bin/bwrap"'
  assert_contains "$readme_file" '`agent codex` can now use Codex'\''s native Bubblewrap sandbox inside the outer container because the image provides `/usr/bin/bwrap`.'
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
      GIT_ALLOW=1 \
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
  assert_contains "$output" "GIT_ALLOW=1"
)

test_ssh_agent_mount_support() (
  set -euo pipefail

  local socket_path output
  socket_path="/tmp/test-ssh-agent.sock"

  output="$(ssh_agent_args_for "$socket_path")"

  assert_contains "$output" "$socket_path:/run/host-services/ssh-auth.sock:rw"
  assert_contains "$output" "SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock"
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
    "/run/agent-path-guard:/agent-sudo/bin:$workspace/node_modules/.bin:/nix/store/bun/bin:/nix/store/node/bin:/bin:"*) ;;
    *) fail "dev env PATH should come before need/image fallback paths: $path_line" ;;
  esac
  assert_contains "$path_line" ":/cache/need/projects/"
  assert_not_contains "$path_line" "/cache/need/bin"
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
    "/run/agent-path-guard:/agent-sudo/bin:$workspace/node_modules/.bin:/cache/need/projects/"*) ;;
    *) fail "runtime PATH should use project-scoped need bins after project-local bins: $output" ;;
  esac
  assert_not_contains "$output" "/cache/need/bin"
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

test_stream_image_helper_uses_docker_helper_attr() (
  set -euo pipefail

  local output
  output="$(stream_image_helper_invocation_for)"

  assert_contains "$output" "TMPDIR="
  assert_contains "$output" "/cache/tmp"
  assert_contains "$output" "argv=run path:/sandbox#streamImage.copyToDockerDaemon --override-input projectPkgs path:/project-store --no-update-lock-file -- --probe flag"
)

test_runtime_identity_mounts_passwd_and_sudo_overlay() (
  set -euo pipefail

  local output
  output="$(runtime_identity_args_for)"

  assert_contains "$output" "/etc/passwd:ro"
  assert_contains "$output" "/etc/group:ro"
  assert_contains "$output" "/etc/sudo.conf:ro"
  assert_contains "$output" "/etc/sudoers:ro"
  assert_contains "$output" "/agent-sudo/bin/sudo:ro"
  assert_contains "$output" "/agent-sudo/bin/sudoedit:ro"
  assert_contains "$output" "USER=agenttest"
  assert_contains "$output" "LOGNAME=agenttest"
  assert_contains "$output" "agenttest:x:"
  assert_contains "$output" "ALL ALL=(ALL:ALL) NOPASSWD: ALL"
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

test_path_guard_excludes_privileged_sudo() (
  set -euo pipefail

  local output
  output="$(path_guard_entries_for)"

  assert_not_contains "$output" "sudo ->"
  assert_not_contains "$output" "sudoedit ->"
)

test_base_container_allows_sudo_privilege_gain() (
  set -euo pipefail

  local output
  output="$(base_container_args_for)"

  assert_contains "$output" "--cap-drop=ALL"
  assert_contains "$output" "--cap-add=SETUID"
  assert_contains "$output" "--cap-add=SETGID"
  assert_not_contains "$output" "--security-opt=no-new-privileges"
)

test_need_run_allows_command_side_sandbox_sudo() (
  set -euo pipefail

  local tmp_dir need_cache installable out_dir bin_dir sudo_dir output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  need_cache="$tmp_dir/need"
  installable="nixpkgs#jq"
  out_dir="$tmp_dir/out"
  bin_dir="$out_dir/bin"
  sudo_dir="$tmp_dir/sandbox-bin"
  mkdir -p "$bin_dir" "$sudo_dir"
  printf '#!/usr/bin/env bash\nprintf "fake-jq\\n"\n' > "$bin_dir/jq"
  printf '#!/usr/bin/env bash\nprintf "sandbox-sudo:%%s\\n" "$*"\n' > "$sudo_dir/sudo"
  chmod +x "$bin_dir/jq" "$sudo_dir/sudo"

  write_need_materialization_cache "$need_cache" "$installable" "$out_dir" "$bin_dir"

  output="$(
    AGENT_NEED_CACHE_DIR="$need_cache" \
    AGENT_NEED_HELPER_DIR="$tmp_dir/missing-helper" \
    PATH="$sudo_dir:/usr/bin:/bin" \
    bash "$REPO_ROOT/scripts/image/need.sh" run "$installable" -- sudo id
  )"

  assert_contains "$output" "sandbox-sudo:id"
)

test_need_run_refuses_materialized_sudo_shadow() (
  set -euo pipefail

  local tmp_dir need_cache installable out_dir bin_dir output status
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  need_cache="$tmp_dir/need"
  installable="nixpkgs#sudo"
  out_dir="$tmp_dir/out"
  bin_dir="$out_dir/bin"
  mkdir -p "$bin_dir"
  printf '#!/usr/bin/env bash\nprintf "unsafe-sudo\\n"\n' > "$bin_dir/sudo"
  chmod +x "$bin_dir/sudo"

  write_need_materialization_cache "$need_cache" "$installable" "$out_dir" "$bin_dir"

  set +e
  output="$(
    AGENT_NEED_CACHE_DIR="$need_cache" \
    AGENT_NEED_HELPER_DIR="$tmp_dir/missing-helper" \
    PATH="/usr/bin:/bin" \
    bash "$REPO_ROOT/scripts/image/need.sh" run "$installable" -- sh -c 'sudo id' 2>&1
  )"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected need run to reject a sudo-providing bin path"
  assert_contains "$output" "refusing to inject privileged command 'sudo'"
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

test_codex_workspace_config_alias_mount() (
  set -euo pipefail

  local tmp_dir workspace config_root output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  config_root="$tmp_dir/codex-home"
  mkdir -p "$workspace" "$config_root"

  output="$(codex_mount_args_for "$workspace" "$config_root")"

  assert_contains "$output" "$config_root:/cache/.codex:rw"
  assert_contains "$output" "$config_root:$workspace/.codex:rw"
  [ -d "$workspace/.codex" ] || fail "expected codex workspace alias target to be created"
)


test_codex_workspace_config_alias_mount_skips_duplicate_path() (
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

test_codex_workspace_config_alias_mount_resolves_symlink_target() (
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
  assert_contains "$output" "$config_root:$shared_config:rw"
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
  assert_contains "$image_file" "sudoPackage = pkgs.sudo.overrideAttrs"
  assert_contains "$image_file" '"--without-pam"'
  assert_contains "$image_file" "sudoConfig"
  assert_contains "$image_file" "sudoRuntime"
  assert_contains "$image_file" "ALL ALL=(ALL:ALL) NOPASSWD: ALL"
  assert_contains "$image_file" "sudoImagePerms"
  assert_contains "$image_file" 'regex = "agent-sudo/bin/sudo$"'
  assert_contains "$image_file" 'regex = "agent-sudo/bin/sudoedit$"'
  assert_contains "$image_file" 'mode = "4755"'
  assert_contains "$image_file" 'rm -rf "$out/agent-sudo"'
  assert_contains "$image_file" 'install -Dm0755 -T "${sudoRuntime}/agent-sudo/bin/sudo" "$out/agent-sudo/bin/sudo"'
  assert_contains "$image_file" 'install -Dm0755 -T "${sudoRuntime}/agent-sudo/bin/sudoedit" "$out/agent-sudo/bin/sudoedit"'
  assert_contains "$image_file" 'install -Dm0440 -T "${sudoConfig}/etc/sudoers.d/agent-sandbox" "$out/etc/sudoers"'
  assert_contains "$image_file" '"$out/run/host-services"'
  assert_contains "$image_file" '"$out/run/agent-path-guard"'
  assert_contains "$rootfs_file" "run/agent-path-guard"
  assert_contains "$artifact_file" "prepare_rootfs_artifact"
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
  run_test "stable fetchTarball uses cached pin" test_stable_fetchtarball_uses_cached_pin
  run_test "mutable channel fetchTarball refreshes stale pin" test_mutable_channel_fetchtarball_refreshes_stale_pin
  run_test "symlinked shell stages resolved nix contract" test_symlinked_shell_stages_resolved_nix_contract
  run_test "git wrapper policy" test_git_wrapper_policy
  run_test "device passthrough support" test_device_passthrough_support
  run_test "kvm smoke script" test_kvm_smoke_script
  run_test "bun latest lookup uses tool cache" test_bun_latest_lookup_uses_tool_cache
  run_test "codex bubblewrap compat path" test_codex_bubblewrap_compat_path
  run_test "workspace mounts for regular repo override" test_workspace_mounts_for_regular_repo_workspace_override
  run_test "workspace mounts for linked worktree override" test_workspace_mounts_for_linked_worktree_workspace_override
  run_test "config selectors are not passthrough env" test_config_selectors_are_not_passthrough_env
  run_test "ssh agent mount support" test_ssh_agent_mount_support
  run_test "ssh runtime generation" test_ssh_runtime_generation
  run_test "dev env path precedence" test_dev_env_path_precedence
  run_test "runtime path uses project-scoped need bins" test_runtime_path_uses_project_scoped_need_bins
  run_test "runtime modes preserve podman rootfs" test_runtime_modes_preserve_podman_rootfs
  run_test "stream image helper uses docker helper attr" test_stream_image_helper_uses_docker_helper_attr
  run_test "runtime identity mounts passwd and sudo overlay" test_runtime_identity_mounts_passwd_and_sudo_overlay
  run_test "stdio target uses podman rootfs" test_stdio_target_uses_podman_rootfs
  run_test "path guard excludes privileged sudo" test_path_guard_excludes_privileged_sudo
  run_test "base container allows sudo privilege gain" test_base_container_allows_sudo_privilege_gain
  run_test "need run allows command-side sandbox sudo" test_need_run_allows_command_side_sandbox_sudo
  run_test "need run refuses materialized sudo shadow" test_need_run_refuses_materialized_sudo_shadow
  run_test "podman session ignores stale reused pid" test_container_api_does_not_kill_stale_reused_pid
  run_test "need clear commands" test_need_clear_commands
  run_test "codex workspace config alias mount" test_codex_workspace_config_alias_mount
  run_test "codex workspace config alias mount skips duplicate path" test_codex_workspace_config_alias_mount_skips_duplicate_path
  run_test "codex workspace config alias mount resolves symlink target" test_codex_workspace_config_alias_mount_resolves_symlink_target
  run_test "codex config dir requires write access" test_codex_config_dir_requires_write_access
  run_test "codex auth file requires read access" test_codex_auth_file_requires_read_access
  run_test "image includes openssh" test_image_includes_openssh
  run_test "need defaults to unstable nixpkgs" test_need_defaults_to_unstable_nixpkgs

  if [ "${AGENT_RUN_KVM_TESTS:-0}" = "1" ]; then
    run_test "microvm smoke" "$REPO_ROOT/tests/kvm-smoke.sh"
  fi
}

main "$@"
