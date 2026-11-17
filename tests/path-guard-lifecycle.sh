#!/usr/bin/env bash
# Mounted command launchers must outlive their launcher when the container does.
set -euo pipefail
repo_root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
fail() { printf '[fail] %s\n' "$*" >&2; exit 1; }

for state in 0 2 1; do
  case_dir="$fixture/state-$state"
  mkdir -p "$case_dir"
  cat > "$case_dir/cli.sh" <<'EOF'
printf 'Orca shim still executable\n'
EOF
  status=0
  bash -c '
    set -euo pipefail
    source "$1/bin/lib/runtime_lease.sh"
    source "$1/bin/lib/container_runtime.sh"
    source "$1/bin/lib/github_app.sh"
    CACHE_DIR="$2/cache"
    RUNTIME_LEASE_DIR="$CACHE_DIR/runtime-leases/sandbox-test"
    RUNTIME_LEASE_PERSIST=0
    HELPER_TMPDIR="$2/tmp"
    mkdir -p "$RUNTIME_LEASE_DIR" "$HELPER_TMPDIR"
    ORCA_ENABLED=1 ORCA_NODE=/bin/bash ORCA_CLI_PATH="$2/cli.sh"
    prepare_path_guard_dir
    printf "%s\n" "$PATH_GUARD_HOST_DIR" > "$2/guard-path"
    "$PATH_GUARD_HOST_DIR/orca-ide" > "$2/before"
    state="$3"
    # 0 means still running; 2 means teardown cannot be confirmed; 1 means gone.
    runtime_lease_bound_container_exists() { return "$state"; }
    RUNTIME_IDENTITY_HOST_DIR="" CODEX_AUTH_PLACEHOLDER=""
    TMP_DIR="" HELPER_STATE_DIR="" LOGIN_STATE_DIR=""
    eval "$(sed -n '\''/^cleanup() {/,/^trap cleanup EXIT/p'\'' "$1/bin/agent")"
    exit 23
  ' lifecycle-probe "$repo_root" "$case_dir" "$state" || status=$?
  [ "$status" -eq 23 ] || fail 'cleanup changed the launcher exit status'
  guard_path="$(cat "$case_dir/guard-path")"
  if [ "$state" -eq 1 ]; then
    [ ! -e "$guard_path" ] || fail 'confirmed teardown retained command launchers'
    [ ! -e "$case_dir/cache/runtime-leases/sandbox-test" ] || fail 'confirmed teardown retained lease'
  else
    [ -x "$guard_path/orca-ide" ] || fail "retained container state $state lost its Orca shim"
    "$guard_path/orca-ide" > "$case_dir/after"
    [ "$(cat "$case_dir/before")" = "$(cat "$case_dir/after")" ] || fail 'retained shim behavior changed'
    # Once teardown is confirmed, the normal lease remover owns these files.
    (
      source "$repo_root/bin/lib/runtime_lease.sh"
      CACHE_DIR="$case_dir/cache"
      remove_runtime_lease "$CACHE_DIR/runtime-leases/sandbox-test"
    )
    [ ! -e "$guard_path" ] || fail 'lease teardown left command launchers behind'
  fi
done
printf '[pass] command launchers follow container lease lifetime\n'
