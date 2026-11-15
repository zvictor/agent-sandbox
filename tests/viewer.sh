#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/bin/lib/environment.sh"
source "$REPO_ROOT/bin/lib/container_runtime.sh"
source "$REPO_ROOT/bin/lib/viewer.sh"

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

# Exercise path selection without building or starting the upstream server.
resolve_sandbox_flake() { :; }
resolve_lock_args() { :; }
compute_sandbox_meta_key() { printf viewer-test; }
hash_short() { runtime_path_scope_key "$1"; }
viewer_should_use_bwrap() { return 1; }

export AGENT_CACHE_DIR="$test_dir/cache"
export AGENT_HOST_HOME="$test_dir/host"
unset CODEX_CONFIG CLAUDE_CONFIG AGENT_PROJECT_CONFIG_FILE AGENT_VIEWER_HOME
unset AGENT_VIEWER_CODEX_HOME AGENT_VIEWER_CLAUDE_HOME
mkdir -p "$AGENT_HOST_HOME/.codex/sessions" "$test_dir/caller" "$test_dir/shared/sessions"

for project in first second; do
  mkdir -p "$test_dir/$project/.claude/projects"
  printf 'CODEX_CONFIG=project\nCLAUDE_CONFIG=project\n' > "$test_dir/$project/.agent-sandbox.env"
done
ln -s ../shared "$test_dir/first/.codex"
mkdir -p "$test_dir/second/.codex/sessions"
cd "$test_dir/caller"

export AGENT_PROJECT_ROOT="$test_dir/first"
viewer_bootstrap_environment
[ "$PWD" = "$test_dir/caller" ]
[ "$PROJECT_CONFIG_FILE" = "$test_dir/first/.agent-sandbox.env" ]
prepare_viewer_home
first_home="$VIEWER_HOME"
[ "$VIEWER_CODEX_TARGET/sessions" -ef "$test_dir/shared/sessions" ]
[ "$VIEWER_CLAUDE_TARGET/projects" -ef "$test_dir/first/.claude/projects" ]

export AGENT_PROJECT_ROOT="$test_dir/second"
viewer_bootstrap_environment
prepare_viewer_home
[ "$VIEWER_HOME" != "$first_home" ]
[ "$VIEWER_CODEX_TARGET/sessions" -ef "$test_dir/second/.codex/sessions" ]
[ "$first_home/.codex/sessions" -ef "$test_dir/shared/sessions" ]

export CODEX_CONFIG=host
viewer_bootstrap_environment
prepare_viewer_home
[ "$VIEWER_CODEX_TARGET/sessions" -ef "$AGENT_HOST_HOME/.codex/sessions" ]

export CODEX_CONFIG=fresh
viewer_bootstrap_environment
prepare_viewer_home
[ -z "$VIEWER_CODEX_SOURCE" ]
[ ! -e "$VIEWER_CODEX_TARGET" ]

export CODEX_CONFIG="$test_dir/shared"
viewer_bootstrap_environment
prepare_viewer_home
[ "$VIEWER_CODEX_TARGET/sessions" -ef "$test_dir/shared/sessions" ]

export AGENT_VIEWER_CODEX_HOME="$AGENT_HOST_HOME/.codex"
prepare_viewer_home
[ "$VIEWER_CODEX_TARGET/sessions" -ef "$AGENT_HOST_HOME/.codex/sessions" ]

printf '[pass] viewer project paths and isolation\n'
