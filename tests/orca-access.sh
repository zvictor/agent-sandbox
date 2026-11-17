#!/usr/bin/env bash
# Offline launcher checks; the runtime protocol has separate integration tests.
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/bin/lib/container_runtime.sh"
source <(sed -n '/^split_csv_or_lines() {/,/^}/p' "$REPO_ROOT/bin/agent")
fail() { printf '[fail] %s\n' "$*" >&2; exit 1; }
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
unset AGENT_ORCA AGENT_ORCA_CLI_PATH AGENT_ORCA_USER_DATA_PATH
unset SANDBOX_PROFILE AGENT_SANDBOX_PROFILE AGENT_REMOTE_CONTAINER_MODE

# Disabled access needs neither a host app nor Nix tooling.
prepare_orca
[ "$ORCA_ENABLED" = 0 ] || fail 'Orca enabled by default'
ARGS=()
append_orca_container_args
[ "${#ARGS[@]}" -eq 0 ] || fail 'disabled integration added mounts'

if (AGENT_ORCA=yes; prepare_orca) >"$test_dir/error" 2>&1; then
  fail 'invalid enable flag accepted'
fi
[[ "$(cat "$test_dir/error")" == *'AGENT_ORCA must be 0 or 1'* ]] || fail 'missing flag diagnostic'

# Unsupported boundaries fail before package discovery or host setup.
for boundary in darwin docker remote firecracker unknown; do
  (
    AGENT_ORCA=1 OS_NAME=Linux RUNTIME=podman
    SANDBOX_PROFILE=default AGENT_REMOTE_CONTAINER_MODE=0
    case "$boundary" in
      darwin) OS_NAME=Darwin ;;
      docker) RUNTIME=docker ;;
      remote) AGENT_REMOTE_CONTAINER_MODE=1 ;;
      firecracker) SANDBOX_PROFILE=firecracker-host ;;
      unknown) SANDBOX_PROFILE=unknown ;;
    esac
    resolve_orca_cli_path() { fail 'unsupported boundary reached package discovery'; }
    if prepare_orca >"$test_dir/error" 2>&1; then
      fail "unsupported $boundary accepted"
    fi
    [[ "$(cat "$test_dir/error")" == *'Orca'* ]] || fail "missing $boundary diagnostic"
    [[ "$(cat "$test_dir/error")" != *'reached package discovery'* ]] || fail "late $boundary rejection"
  )
done

# Store-root parsing must not reinterpret ordinary filesystem paths as roots.
[ "$(orca_store_root /nix/store/example-orca/resources/app.asar.unpacked/out/cli/index.js)" = /nix/store/example-orca ] || fail 'incorrect package root'
if orca_store_root "$test_dir/package" >"$test_dir/error" 2>&1; then
  fail 'non-store package accepted'
fi

# A real matching CLI fixture outside the store must still be rejected.
fixture_cli="$test_dir/package/resources/app.asar.unpacked/out/cli/index.js"
mkdir -p "$(dirname "$fixture_cli")"
touch "$fixture_cli"
(
  AGENT_ORCA_CLI_PATH="$fixture_cli"
  retain_runtime_artifact() { fail 'non-store package was retained'; }
  if resolve_orca_cli_path >"$test_dir/error" 2>&1; then
    fail 'non-store explicit CLI accepted'
  fi
  [[ "$(cat "$test_dir/error")" == *'Nix-store installation'* ]] || fail 'missing non-store diagnostic'
)
(
  AGENT_ORCA_CLI_PATH="$test_dir/wrong-entry.js"
  touch "$AGENT_ORCA_CLI_PATH"
  if resolve_orca_cli_path >"$test_dir/error" 2>&1; then
    fail 'incorrect packaged CLI entry accepted'
  fi
  [[ "$(cat "$test_dir/error")" == *'must name the packaged'* ]] || fail 'missing entry diagnostic'
)

# Run the generated shim with spaces in both executable and CLI paths. Check
# exact arguments, stream separation, runtime profile selection and exit status.
PATH_GUARD_HOST_DIR="$test_dir/path guard"
mkdir -p "$PATH_GUARD_HOST_DIR" "$test_dir/fake runtime"
ORCA_ENABLED=1
ORCA_NODE="$test_dir/fake runtime/node"
ORCA_CLI_PATH="$fixture_cli"
cat >"$ORCA_NODE" <<'EOF'
#!/bin/bash
set -eu
[ "$1" = "$EXPECTED_CLI" ] || exit 90
[ "$ORCA_USER_DATA_PATH" = /run/agent-orca ] || exit 91
shift
printf '%s\0' "$@"
printf '%s\n' 'fixture stderr' >&2
exit 17
EOF
chmod 0755 "$ORCA_NODE"
prepare_orca_commands
export EXPECTED_CLI="$fixture_cli"
expected_args=('one argument' '' 'literal $HOME; $(false)' $'two\nlines')
for cli_name in orca-ide orca; do
  shim_status=0
  PATH="$PATH_GUARD_HOST_DIR:$PATH" "$cli_name" "${expected_args[@]}" >"$test_dir/stdout" 2>"$test_dir/stderr" || shim_status=$?
  [ "$shim_status" -eq 17 ] || fail "$cli_name lost exit status"
  mapfile -d '' -t received_args <"$test_dir/stdout"
  [ "${#received_args[@]}" -eq "${#expected_args[@]}" ] || fail "$cli_name changed argument count or stdout"
  for index in "${!expected_args[@]}"; do
    [ "${received_args[$index]}" = "${expected_args[$index]}" ] || fail "$cli_name changed arguments or stdout"
  done
  [ "$(cat "$test_dir/stderr")" = 'fixture stderr' ] || fail "$cli_name changed stderr"
done

ORCA_PROJECTION_DIR="$test_dir/lease/orca/runtime"
ARGS=()
append_orca_container_args
[ "${#ARGS[@]}" -eq 6 ] || fail 'unexpected Orca mounts or environment'
[ "${ARGS[0]}" = -v ] && [ "${ARGS[1]}" = "$ORCA_PROJECTION_DIR:/run/agent-orca:ro" ] || fail 'incorrect private runtime mount'
[ "${ARGS[2]}" = -e ] && [ "${ARGS[3]}" = ORCA_USER_DATA_PATH=/run/agent-orca ] || fail 'incorrect projected profile'
[ "${ARGS[4]}" = -e ] && [ "${ARGS[5]}" = ORCA_CLI_COMMAND=/run/agent-path-guard/orca-ide ] || fail 'incorrect CLI selection'

# User overrides must not retarget the integration after its capability grant.
for key in ORCA_CLI_COMMAND ORCA_USER_DATA_PATH; do
  if (AGENT_EXTRA_ENV="$key=/other"; ARGS=(); append_extra_env_args) >"$test_dir/error" 2>&1; then
    fail "extra environment replaced $key"
  fi
  [[ "$(cat "$test_dir/error")" == *'cannot override runtime-owned variable'* ]] || fail "missing reserved $key diagnostic"
done
(
  export AGENT_ORCA=1 AGENT_ORCA_CLI_PATH=/host/cli AGENT_ORCA_USER_DATA_PATH=/host/profile
  export ORCA_CLI_COMMAND=/other/cli ORCA_USER_DATA_PATH=/other/profile
  export ORCA_TEST_VALUE=allowed
  AGENT_PASS_ENV_PREFIXES=$'AGENT_ORCA\nORCA_'
  ARGS=()
  append_passthrough_env_args
  [ "${#ARGS[@]}" -eq 2 ] && [ "${ARGS[0]}" = -e ] && [ "${ARGS[1]}" = ORCA_TEST_VALUE=allowed ] || fail 'passthrough exposed selectors or replaced connection'
)

ORCA_ENABLED=0
prepare_orca_commands
[ ! -e "$PATH_GUARD_HOST_DIR/orca-ide" ] || fail 'disabled access retained stale shim'
[ ! -e "$PATH_GUARD_HOST_DIR/orca" ] && [ ! -L "$PATH_GUARD_HOST_DIR/orca" ] || fail 'disabled access retained stale alias'

# Remote startup has its own entry path; it must reject the capability too.
(
  source "$REPO_ROOT/bin/lib/remote.sh"
  AGENT_ORCA=1
  remote_reject_implicit_host_bridges
) >"$test_dir/error" 2>&1 && fail 'remote startup accepted Orca access'
[[ "$(cat "$test_dir/error")" == *'Orca integration is unavailable in remote mode'* ]] || fail 'missing remote rejection'

echo '[pass] Orca access launcher'
