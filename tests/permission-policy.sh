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
[ "$PERMISSION_POLICY" = native ] || fail "rootless default"
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
  if output="$(AGENT_PERMISSION_POLICY=native apply_tool_permission_policy "${bypass_args[@]}" 2>&1)"; then
    fail "native accepted bypass: $spec"
  fi
  assert_contains "$output" 'conflicts with native permission policy'
  assert_contains "$output" "AGENT_PERMISSION_POLICY=container agent ${bypass_args[0]}"
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
if apply_tool_permission_policy codex --yolo 2>/dev/null; then fail "profile-native accepted bypass"; fi
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
apply_tool_permission_policy claude -p --permission-mode
[ "${PERMISSION_TOOL_ARGS[-1]}" = --permission-mode ] || fail "prompt treated as option"

PROJECT_ROOT="$test_dir/workspace"
mkdir -p "$PROJECT_ROOT" "$test_dir/shared"
ln -s ../shared "$PROJECT_ROOT/.codex"
if output="$(AGENT_PERMISSION_POLICY=native apply_tool_permission_policy codex -s workspace-write -C "$PROJECT_ROOT" 2>&1)"; then fail "native writable symlink accepted"; fi
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
echo '[test] shared defaults, adapters, conflicts, symlinks and policy refresh passed'
