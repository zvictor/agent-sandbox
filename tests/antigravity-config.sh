#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/bin/lib/container_runtime.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

HOST_HOME="$tmp_dir/host"
PROJECT_ROOT="$tmp_dir/project-one"
CACHE_DIR="$tmp_dir/cache"
HELPER_TMPDIR="$tmp_dir/tmp"
Z_SUFFIX=""
mkdir -p "$HOST_HOME/.gemini" "$PROJECT_ROOT" "$HELPER_TMPDIR"
touch "$HOST_HOME/.gemini/host-session-marker"

fail() { printf '[fail] %s\n' "$*" >&2; exit 1; }

check_mount() {
  local expected_mode="$1"
  local expected_config="$2"
  local expected_mount="$3"
  local actual_args

  resolve_tool_config_roots
  [ "$ANTIGRAVITY_CONFIG_MODE" = "$expected_mode" ] || fail "wrong Antigravity mode: $ANTIGRAVITY_CONFIG_MODE"
  [ "$ANTIGRAVITY_HOST_CONFIG" = "$expected_config" ] || fail "wrong Antigravity config path: $ANTIGRAVITY_HOST_CONFIG"

  ARGS=()
  mount_standard_engine antigravity
  actual_args="$(printf '%s\n' "${ARGS[@]}")"
  case "$actual_args" in
    *"$expected_mount:/cache/.gemini:rw"*) ;;
    *) fail "missing Antigravity mount $expected_mount in: $actual_args" ;;
  esac
}

# Default and explicit host mode preserve the existing shared sessions.
unset ANTIGRAVITY_CONFIG
check_mount host "$HOST_HOME/.gemini" "$HOST_HOME/.gemini"
ANTIGRAVITY_CONFIG=host
check_mount host "$HOST_HOME/.gemini" "$HOST_HOME/.gemini"

# Project mode relocates the entire CLI home, including its session data.
ANTIGRAVITY_CONFIG=project
check_mount project "$PROJECT_ROOT/.gemini" "$PROJECT_ROOT/.gemini"
[ -d "$PROJECT_ROOT/.gemini" ] || fail 'project home was not created'
[ ! -e "$PROJECT_ROOT/.gemini/host-session-marker" ] || fail 'host sessions leaked into project home'
[ -e "$HOST_HOME/.gemini/host-session-marker" ] || fail 'host sessions were modified'

# Changing project roots must change the persistent Antigravity mount.
PROJECT_ROOT="$tmp_dir/project-two"
mkdir -p "$PROJECT_ROOT"
check_mount project "$PROJECT_ROOT/.gemini" "$PROJECT_ROOT/.gemini"
[ ! -e "$PROJECT_ROOT/.gemini/host-session-marker" ] || fail 'host sessions leaked into second project'

# Explicit selectors behave like the other supported agents.
ANTIGRAVITY_CONFIG=./custom-gemini
check_mount path "$PROJECT_ROOT/custom-gemini" "$PROJECT_ROOT/custom-gemini"

# Fresh state is runtime-local, not shared with the host or project homes.
ANTIGRAVITY_CONFIG=fresh
resolve_tool_config_roots
[ "$ANTIGRAVITY_CONFIG_MODE" = fresh ] || fail 'fresh mode not selected'
[ -z "$ANTIGRAVITY_HOST_CONFIG" ] || fail 'fresh config root should be empty'
ARGS=()
mount_standard_engine antigravity
[ -d "$CONFIG_STATE_DIR/antigravity" ] || fail 'fresh runtime state was not created'
fresh_args="$(printf '%s\n' "${ARGS[@]}")"
case "$fresh_args" in
  *"$CONFIG_STATE_DIR/antigravity:/cache/.gemini:rw"*) ;;
  *) fail 'fresh state was not mounted into Antigravity home' ;;
esac

printf '[ok] Antigravity config selectors and project-local sessions\n'
