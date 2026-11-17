#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/bin/lib/container_runtime.sh"
fail() { echo "[fail] $*" >&2; exit 1; }
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
HOST_HOME="$test_dir/host home"
mkdir -p "$HOST_HOME"
Z_SUFFIX=,z
ARGS=()
append_host_agent_resources_args
[ "${#ARGS[@]}" = 0 ] || fail "absent host resources added a mount"
[ ! -e "$HOST_HOME/.agents" ] || fail "absent host resources were created"

mkdir -p "$HOST_HOME/.agents/skills/orchestration"
printf '%s\n' '---' 'name: orchestration' 'description: Coordinate agents.' '---' > "$HOST_HOME/.agents/skills/orchestration/SKILL.md"
agents_dir="$(cd "$HOST_HOME/.agents" && pwd -P)"

# Exercise the shared launch path without preparing or running a container.
# Every tool and config selection must get the host resources mount.
for hook in resolve_permission_policy validate_tool_permission_args \
  prepare_tool_cache_dirs prepare_path_guard_dir build_nix_config \
  resolve_tool_config_roots build_base_container_args append_path_guard_mount_args \
  append_nix_mount_args append_runtime_receipt_mount_args \
  append_runtime_identity_mount_args append_runtime_identity_args \
  append_firecracker_host_args append_host_socket_args append_ssh_runtime_mount_args \
  append_remote_state_mount_args append_dev_env_args append_workspace_mount_args \
  append_extra_env_args append_auto_mount_dir_args append_split_arg_values \
  append_extra_device_args append_passthrough_env_args mount_tool_configs \
  append_github_app_container_args append_stdio_and_target_args \
  validate_container_mount_safety; do
  eval "$hook() { :; }"
done
RUNTIME=docker
PROJECT_ROOT="$test_dir/project"
PERMISSION_POLICY=container
REMAINING_ARGS=()
for TOOL in codex claude opencode antigravity omp commandcode codemachine; do
  for CODEX_CONFIG in host project fresh; do
    for AGENT_REMOTE_CONTAINER_MODE in 0 1; do
      ARGS=()
      build_container_args
      [ "${ARGS[0]}" = -v ] || fail "$TOOL/$CODEX_CONFIG missing resources volume"
      [ "${ARGS[1]}" = "$agents_dir:/cache/.agents:ro,z" ] || fail "$TOOL/$CODEX_CONFIG incorrect resources mount"
    done
  done
done

# Resolve a symlink at the mount root, including targets outside the host home.
mv "$HOST_HOME/.agents" "$test_dir/shared agents"
ln -s '../shared agents' "$HOST_HOME/.agents"
ARGS=()
append_host_agent_resources_args
agents_dir="$(cd "$test_dir/shared agents" && pwd -P)"
[ "${ARGS[1]}" = "$agents_dir:/cache/.agents:ro,z" ] || fail "root symlink was not resolved"

rm "$HOST_HOME/.agents"
ln -s missing "$HOST_HOME/.agents"
if build_container_args > "$test_dir/error" 2>&1; then
  fail "broken resources symlink allowed launch"
fi
[[ "$(cat "$test_dir/error")" == *'host agent resources must resolve to an existing directory'* ]] || fail "missing broken-link diagnostic"
rm "$HOST_HOME/.agents"
touch "$HOST_HOME/.agents"
if build_container_args > "$test_dir/error" 2>&1; then
  fail "resources file allowed launch"
fi

echo '[pass] host agent resources mounts'
