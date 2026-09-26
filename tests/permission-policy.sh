#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/bin/lib/container_runtime.sh"
source "$REPO_ROOT/bin/lib/doctor.sh"
fail() { echo "[fail] $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "missing $2"; }
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
unset AGENT_PERMISSION_POLICY OPENCODE_PERMISSION
SANDBOX_PROFILE=default
resolve_permission_policy
[ "$PERMISSION_POLICY" = container ] || fail "standard default"
SANDBOX_PROFILE=rootless-linux
resolve_permission_policy
[ "$PERMISSION_POLICY" = container ] || fail "rootless default"
for profile in default rootless-linux firecracker-host; do
  SANDBOX_PROFILE="$profile"
  for tool in codex claude opencode antigravity omp commandcode codemachine; do
    unset OPENCODE_PERMISSION
    apply_tool_permission_policy "$tool" --help
    [ "$PERMISSION_POLICY" = container ] || fail "$profile/$tool requires a policy override"
    [ "$PERMISSION_POLICY_SOURCE" = 'container default' ] || fail "$profile/$tool depends on profile"
    case "$tool" in
      codex|omp|commandcode) [ "${PERMISSION_TOOL_ARGS[0]}" = --yolo ] || fail "$profile/$tool bypass" ;;
      claude|antigravity) [ "${PERMISSION_TOOL_ARGS[0]}" = --dangerously-skip-permissions ] || fail "$profile/$tool bypass" ;;
      opencode) [ "$OPENCODE_PERMISSION" = '{"*":"allow"}' ] || fail "$profile/OpenCode permissions" ;;
      codemachine) [ "${PERMISSION_TOOL_ARGS[*]}" = --help ] || fail "composite arguments changed" ;;
    esac
  done
done
unset OPENCODE_PERMISSION
SANDBOX_PROFILE=rootless-linux
AGENT_PERMISSION_POLICY=container
resolve_permission_policy
[ "$PERMISSION_POLICY" = container ] || fail "explicit override"

for tool in codex claude opencode antigravity omp commandcode codemachine; do
  apply_tool_permission_policy "$tool" --help
  case "$tool" in
    codex|omp|commandcode) [ "${PERMISSION_TOOL_ARGS[0]}" = --yolo ] || fail "$tool bypass" ;;
    claude|antigravity) [ "${PERMISSION_TOOL_ARGS[0]}" = --dangerously-skip-permissions ] || fail "$tool bypass" ;;
    opencode) [ "$OPENCODE_PERMISSION" = '{"*":"allow"}' ] || fail "invalid OpenCode JSON" ;;
  esac
done
apply_tool_permission_policy codex --yolo --help
[ "${#PERMISSION_TOOL_ARGS[@]}" = 2 ] || fail "duplicate bypass flag"
apply_tool_permission_policy claude --dangerously-skip-permissions --help
[ "${#PERMISSION_TOOL_ARGS[@]}" = 4 ] || fail "duplicate Claude bypass"
for tool in codex claude opencode antigravity omp commandcode; do
  AGENT_PERMISSION_POLICY=native apply_tool_permission_policy "$tool" --help
  [ "${#PERMISSION_TOOL_ARGS[@]}" = 1 ] || fail "$tool native changed args"
done
for spec in \
  'codex --yolo' \
  'codex --dangerously-bypass-approvals-and-sandbox' \
  'codex --sandbox danger-full-access' \
  'codex --sandbox=danger-full-access' \
  'codex -a never' \
  'claude --dangerously-skip-permissions' \
  'claude --permission-mode bypassPermissions' \
  'antigravity --dangerously-skip-permissions' \
  'omp --yolo' \
  'omp --auto-approve' \
  'commandcode --yolo' \
  'commandcode --dangerously-skip-permissions' \
  'commandcode --permission-mode=yolo'; do
  read -r -a bypass_args <<< "$spec"
  AGENT_PERMISSION_POLICY=native apply_tool_permission_policy "${bypass_args[@]}"
  [ "${PERMISSION_TOOL_ARGS[*]}" = "${bypass_args[*]:1}" ] || fail "native altered explicit controls: $spec"
done
AGENT_PERMISSION_POLICY=native apply_tool_permission_policy claude -p --dangerously-skip-permissions
AGENT_PERMISSION_POLICY=native apply_tool_permission_policy codex -- --yolo
AGENT_PERMISSION_POLICY=native apply_tool_permission_policy codex -a on-request -s read-only
unset AGENT_PERMISSION_POLICY
SANDBOX_PROFILE=default
apply_tool_permission_policy codex --yolo
[ "$PERMISSION_POLICY" = container ] || fail "ordinary bypass launch needs explicit policy"
[ "${#PERMISSION_TOOL_ARGS[@]}" = 1 ] || fail "ordinary bypass duplicated"
SANDBOX_PROFILE=rootless-linux
apply_tool_permission_policy codex --yolo
[ "$PERMISSION_POLICY" = container ] || fail "rootless bypass selected native"
[ "$PERMISSION_POLICY_SOURCE" = 'tool permission bypass' ] || fail "missing bypass source"
SANDBOX_PROFILE=default
for spec in \
  'codex --sandbox workspace-write' \
  'codex --sandbox=read-only --ask-for-approval=never' \
  'codex --ask-for-approval never' \
  'codex --sandbox danger-full-access' \
  'codex -P :workspace' \
  'codex --permission-profile=:read-only' \
  'codex --profile custom' \
  'codex --config approval_policy="never"' \
  'claude --permission-mode default' \
  'claude -p --permission-mode plan' \
  'commandcode --permission-mode plan' \
  'commandcode --plan' \
  'antigravity --sandbox'; do
  read -r -a control_args <<< "$spec"
  apply_tool_permission_policy "${control_args[@]}"
  [ "$PERMISSION_POLICY" = native ] || fail "controls did not select native: $spec"
  [ "$PERMISSION_POLICY_SOURCE" = 'tool permission controls' ] || fail "missing control source"
  [ "${PERMISSION_TOOL_ARGS[*]}" = "${control_args[*]:1}" ] || fail "controls changed: $spec"
done
apply_tool_permission_policy codex -c 'model="example"'
[ "$PERMISSION_POLICY" = container ] || fail "unrelated config selected native"
apply_tool_permission_policy codex -c 'sandbox_mode = "read-only"'
[ "$PERMISSION_POLICY" = native ] || fail "spaced permission config ignored"
apply_tool_permission_policy codex exec sandbox
[ "$PERMISSION_POLICY" = container ] || fail "positional prompt treated as sandbox subcommand"
apply_tool_permission_policy codex sandbox -P :workspace -- /bin/true
[ "$PERMISSION_POLICY" = native ] || fail "sandbox subcommand got bypass"
apply_tool_permission_policy claude --settings '{"sandbox":{"enabled":true}}'
[ "$PERMISSION_POLICY" = native ] || fail "Claude settings overwritten"
apply_tool_permission_policy claude --append-system-prompt --dangerously-skip-permissions
[ "${PERMISSION_TOOL_ARGS[0]}" = --dangerously-skip-permissions ] || fail "prompt suppressed bypass injection"
[ "${#PERMISSION_TOOL_ARGS[@]}" = 5 ] || fail "prompt was parsed as bypass"
for spec in 'codex --yolo --sandbox read-only' 'claude --dangerously-skip-permissions --permission-mode plan'; do
  read -r -a conflicting_args <<< "$spec"
  if apply_tool_permission_policy "${conflicting_args[@]}" 2>/dev/null; then fail "contradictory flags accepted"; fi
done
OPENCODE_PERMISSION='{"bash":"ask"}' apply_tool_permission_policy opencode --help
[ "$PERMISSION_POLICY" = native ] || fail "OpenCode override overwritten by auto policy"
AGENT_PERMISSION_POLICY=container apply_tool_permission_policy codex --yolo
AGENT_PERMISSION_POLICY=native apply_tool_permission_policy codex --yolo
[ "$PERMISSION_POLICY" = native ] || fail "explicit native did not win over bypass"
AGENT_PERMISSION_POLICY=container
OPENCODE_PERMISSION='{"bash":"ask"}'
AGENT_PERMISSION_POLICY=native apply_tool_permission_policy opencode --help
[ "$OPENCODE_PERMISSION" = '{"bash":"ask"}' ] || fail "native overwrote user permissions"
if apply_tool_permission_policy opencode --help 2>/dev/null; then fail "conflicting OpenCode override accepted"; fi
unset OPENCODE_PERMISSION
OPENCODE_PERMISSION='"allow"' apply_tool_permission_policy opencode --help
OPENCODE_PERMISSION='{ "*": "allow" }' apply_tool_permission_policy opencode --help
if AGENT_PERMISSION_POLICY=native apply_tool_permission_policy codemachine --help 2>/dev/null; then fail "unsupported composite accepted"; fi
if AGENT_PERMISSION_POLICY=invalid resolve_permission_policy 2>/dev/null; then fail "invalid policy accepted"; fi
if apply_tool_permission_policy codex --sandbox workspace-write 2>/dev/null; then fail "conflicting sandbox accepted"; fi
if apply_tool_permission_policy codex --config 'sandbox_mode="read-only"' 2>/dev/null; then fail "conflicting config accepted"; fi
if apply_tool_permission_policy claude --permission-mode plan 2>/dev/null; then fail "conflicting Claude mode accepted"; fi
apply_tool_permission_policy claude --append-system-prompt --permission-mode
[ "${PERMISSION_TOOL_ARGS[-1]}" = --permission-mode ] || fail "prompt treated as option"

PROJECT_ROOT="$test_dir/workspace"
mkdir -p "$PROJECT_ROOT" "$test_dir/shared"
ln -s ../shared "$PROJECT_ROOT/.codex"
if output="$(AGENT_PERMISSION_POLICY=native apply_tool_permission_policy codex -s workspace-write -C "$PROJECT_ROOT" 2>&1)"; then fail "native writable symlink accepted"; fi
assert_contains "$output" 'cannot protect writable symlink'
if output="$(AGENT_PERMISSION_POLICY= apply_tool_permission_policy codex -s workspace-write -C "$PROJECT_ROOT" 2>&1)"; then fail "inferred native writable symlink accepted"; fi
assert_contains "$output" 'cannot protect writable symlink'
mkdir -p "$PROJECT_ROOT/src"
AGENT_PERMISSION_POLICY=native apply_tool_permission_policy codex -s workspace-write -C "$PROJECT_ROOT/src"
AGENT_PERMISSION_POLICY=native apply_tool_permission_policy codex -s read-only
apply_tool_permission_policy codex --help
[ "$(readlink "$PROJECT_ROOT/.codex")" = ../shared ] || fail "symlink mutated"
resolve_permission_policy
[ -z "$(doctor_permission_notes)" ] || fail "container got native symlink warning"
AGENT_PERMISSION_POLICY=native resolve_permission_policy
assert_contains "$(doctor_permission_notes)" 'Codex workspace-write cannot protect writable symlink'
AGENT_PERMISSION_POLICY=container resolve_permission_policy

RUNTIME_LEASE_DIR="$test_dir/lease"
TOOL=codex
REMAINING_ARGS=()
mkdir -p "$RUNTIME_LEASE_DIR"
Z_SUFFIX=""
ARGS=()
prepare_codex_permission_config
assert_contains "$(cat "$CODEX_PERMISSION_CONFIG_DIR/requirements.toml")" '":danger-full-access" = true'
bun -e 'const cfg = Bun.TOML.parse(await Bun.file(process.argv[1]).text()); if (cfg.default_permissions !== ":danger-full-access" || cfg.allowed_approval_policies.length !== 1 || cfg.allowed_approval_policies[0] !== "never") process.exit(1)' "$CODEX_PERMISSION_CONFIG_DIR/requirements.toml"
assert_contains "${ARGS[*]}" ':/etc/codex:ro'
first_config="$CODEX_PERMISSION_CONFIG_DIR"
AGENT_PERMISSION_POLICY=native prepare_codex_permission_config
[ "$CODEX_PERMISSION_CONFIG_DIR" != "$first_config" ] || fail "policy reused across launches"
[ ! -e "$CODEX_PERMISSION_CONFIG_DIR/requirements.toml" ] || fail "native retained container requirements"
! rg -q 'sandbox_mode|approval_policy' "$CODEX_PERMISSION_CONFIG_DIR/config.toml" || fail "native policy pinned permissions"
unset AGENT_PERMISSION_POLICY
REMAINING_ARGS=(--sandbox read-only --ask-for-approval never)
prepare_codex_permission_config
[ "$PERMISSION_POLICY" = native ] || fail "config generation re-resolved to profile default"
[ ! -e "$CODEX_PERMISSION_CONFIG_DIR/requirements.toml" ] || fail "inferred native retained requirements"
REMAINING_ARGS=(--yolo)
prepare_codex_permission_config
[ -e "$CODEX_PERMISSION_CONFIG_DIR/requirements.toml" ] || fail "inferred container lost requirements"
# The resolved policy travels into the image; child flags cannot change it.
if AGENT_PERMISSION_POLICY="$PERMISSION_POLICY" apply_tool_permission_policy codex --sandbox read-only 2>/dev/null; then
  fail "child switched existing container policy"
fi
(
  # Exercise the actual host preflight entrypoint before any runtime artifacts.
  source "$REPO_ROOT/bin/lib/environment.sh"
  prepare_tool_resolution_context() { :; }
  resolve_sandbox_profile() { SANDBOX_PROFILE=default; }
  resolve_runtime() { [ "$PERMISSION_POLICY" = native ] || fail "preflight lost CLI controls"; }
  preflight_firecracker_host_profile() { :; }
  preflight_rootless_linux_profile() { :; }
  resolve_sandbox_flake() { :; }
  resolve_lock_args() { :; }
  prepare_project_contract_input() { :; }
  resolve_direnv_nix_path() { :; }
  prepare_dev_env_state() { :; }
  prepare_project_store_input() { :; }
  REMAINING_ARGS=(--sandbox read-only --ask-for-approval never)
  bootstrap_environment
)
(
  # Verify the actual container command gets the default even with an image
  # launcher that does nothing except forward argv to native Antigravity.
  unset AGENT_PERMISSION_POLICY
  TOOL=antigravity
  SANDBOX_PROFILE=default
  MODE=podman-rootfs
  ROOTFS_IMAGE_ARG=/tmp/test-rootfs:O
  REMAINING_ARGS=(-p 'inspect flow-intro files')
  ARGS=()
  append_stdio_and_target_args
  [ "${ARGS[-3]}" = --dangerously-skip-permissions ] || fail "host omitted Antigravity bypass"
  [ "${ARGS[-1]}" = 'inspect flow-intro files' ] || fail "host changed prompt quoting"
  [ "${#REMAINING_ARGS[@]}" = 2 ] || fail "host mutated user controls"
  # Modern image launchers must not add the bypass again.
  apply_tool_permission_policy antigravity "${ARGS[@]: -3}"
  [ "${#PERMISSION_TOOL_ARGS[@]}" = 3 ] || fail "image duplicated host bypass"
  ARGS=()
  REMAINING_ARGS=(--dangerously-skip-permissions -p 'inspect flow-intro files')
  append_stdio_and_target_args
  count=0
  for arg in "${ARGS[@]}"; do
    if [ "$arg" = --dangerously-skip-permissions ]; then count=$((count + 1)); fi
  done
  [ "$count" = 1 ] || fail "host duplicated explicit bypass"
  ARGS=()
  REMAINING_ARGS=(-p 'inspect flow-intro files')
  AGENT_PERMISSION_POLICY=native append_stdio_and_target_args
  [ "${ARGS[-3]}" = /tmp/test-rootfs:O ] || fail "native shortcut added bypass"
  ARGS=()
  REMAINING_ARGS=(--sandbox -p 'inspect flow-intro files')
  append_stdio_and_target_args
  [ "${ARGS[-3]}" = --sandbox ] || fail "host replaced native sandbox control"
  ARGS=()
  REMAINING_ARGS=(-p 'inspect flow-intro files')
  SANDBOX_PROFILE=rootless-linux
  append_stdio_and_target_args
  [ "${ARGS[-4]}" = /bin/agent-rootless-linux-entrypoint ] || fail "rootless entrypoint replaced"
  [ "${ARGS[-3]}" = --dangerously-skip-permissions ] || fail "rootless Antigravity omitted bypass"
  ARGS=()
  REMAINING_ARGS=(--conversation=00000000-0000-4000-8000-000000000000)
  append_stdio_and_target_args
  [ "${ARGS[-2]}" = --dangerously-skip-permissions ] || fail "rootless resumed conversation omitted bypass"
  [ "${ARGS[-1]}" = "${REMAINING_ARGS[0]}" ] || fail "conversation ID changed"
)
(
  # Host Codex shortcuts must also work with an argv-only cached image wrapper.
  unset AGENT_PERMISSION_POLICY
  TOOL=codex
  SANDBOX_PROFILE=rootless-linux
  MODE=podman-rootfs
  ROOTFS_IMAGE_ARG=/tmp/test-rootfs:O
  SSH_RUNTIME_DIR=""
  REMAINING_ARGS=(resume test-session)
  ARGS=()
  append_stdio_and_target_args
  [ "${ARGS[-4]}" = /bin/agent-rootless-linux-entrypoint ] || fail "Codex rootless entrypoint replaced"
  [ "${ARGS[-3]}" = --yolo ] || fail "rootless Codex omitted bypass"
  [ "${ARGS[-2]} ${ARGS[-1]}" = 'resume test-session' ] || fail "resume args changed"
  [ "${REMAINING_ARGS[*]}" = 'resume test-session' ] || fail "host mutated Codex args"
  apply_tool_permission_policy codex "${ARGS[@]: -3}"
  [ "${#PERMISSION_TOOL_ARGS[@]}" = 3 ] || fail "Codex image duplicated host bypass"
  ARGS=()
  REMAINING_ARGS=(--yolo resume test-session)
  append_stdio_and_target_args
  count=0
  for arg in "${ARGS[@]}"; do
    if [ "$arg" = --yolo ]; then count=$((count + 1)); fi
  done
  [ "$count" = 1 ] || fail "Codex host duplicated explicit bypass"
  ARGS=()
  REMAINING_ARGS=(--sandbox read-only --ask-for-approval never)
  append_stdio_and_target_args
  [ "$PERMISSION_POLICY" = native ] || fail "rootless ignored native CLI controls"
  [[ "${ARGS[*]}" != *--yolo* ]] || fail "rootless native controls got bypass"
  [ "${ARGS[-4]} ${ARGS[-3]} ${ARGS[-2]} ${ARGS[-1]}" = "${REMAINING_ARGS[*]}" ] || fail "native CLI controls changed"
  ARGS=()
  REMAINING_ARGS=(resume test-session)
  AGENT_PERMISSION_POLICY=native append_stdio_and_target_args
  [[ "${ARGS[*]}" != *--yolo* ]] || fail "rootless native override got bypass"
  ARGS=()
  REMAINING_ARGS=()
  prepare_codex_permission_config
  [ "$PERMISSION_POLICY" = container ] || fail "rootless policy config defaulted to native"
  assert_contains "$(cat "$CODEX_PERMISSION_CONFIG_DIR/config.toml")" 'sandbox_mode = "danger-full-access"'
  [ -e "$CODEX_PERMISSION_CONFIG_DIR/requirements.toml" ] || fail "rootless default lacks requirements"
  [ -z "$(doctor_permission_notes)" ] || fail "rootless container got native symlink warning"
)
(
  # Changing permission handling must not change the outer rootless boundary.
  SANDBOX_PROFILE=rootless-linux
  AGENT_ALLOW_SUDO=0
  AGENT_REMOTE_CONTAINER_MODE=0
  RUNTIME=podman
  OS_NAME=Linux
  ROOTLESS_NETWORK_BACKEND=pasta
  SANDBOX_TMP_DIR="$test_dir"
  TOOL=codex
  WORKSPACE_PATH="$PROJECT_ROOT"
  WORKSPACE_RUNTIME_PATH=/bin:/usr/bin
  TOOL_CACHE_DIR="$test_dir/cache"
  NEED_TOOLS_PATH="$test_dir/need"
  NIX_CONFIG='sandbox = false'
  outer_args=""
  for policy in native container; do
    AGENT_PERMISSION_POLICY="$policy"
    apply_tool_permission_policy codex
    build_base_container_args
    append_runtime_identity_args
    # Only the generated container name varies between builds.
    current_args="$(printf '%q ' "${ARGS[@]:2}")"
    if [ -n "$outer_args" ]; then
      [ "$current_args" = "$outer_args" ] || fail "permissions changed outer isolation"
    fi
    outer_args="$current_args"
  done
  assert_contains "$outer_args" --cap-drop=ALL
  assert_contains "$outer_args" --security-opt=no-new-privileges
  assert_contains "$outer_args" --cgroupns=private
  assert_contains "$outer_args" --network=pasta
  assert_contains "$outer_args" --uidmap
  assert_contains "$outer_args" --pids-limit=512
)
echo '[test] shared defaults, adapters, conflicts, symlinks and policy refresh passed'
