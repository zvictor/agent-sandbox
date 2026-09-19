#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/image/rootless-linux-lifecycle.sh"
fixture="$(mktemp -d)"
cleanup() {
  local pid_file pid
  for pid_file in "$fixture"/*.pid "$fixture"/*/*.pid; do
    [ -f "$pid_file" ] || continue
    read -r pid < "$pid_file"
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$fixture"
}
trap cleanup EXIT
fail() { echo "[fail] $*" >&2; exit 1; }

mkdir "$fixture/bin" "$fixture/units"
export SYSTEMD_UNIT_PATH="$fixture/units"
for unit in basic.target exit.target systemd-exit.service shutdown.target; do
  : > "$SYSTEMD_UNIT_PATH/$unit"
done
cat > "$fixture/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$2" = show ]; then
  if [ "${TEST_BAD_UNIT:-}" = "${@: -1}" ]; then
    echo not-found
  else
    echo loaded
  fi
  exit 0
fi
[ "$*" = '--user exit' ] || exit 99
printf 'request\n' >> "$TEST_FIXTURE/requests"
case "$TEST_MODE" in
  graceful)
    kill "$TEST_MANAGER_PID"
    printf 'populated 0\n' > "$TEST_FIXTURE/cgroup.events"
    ;;
  missing|interrupt|term|replaced-path|wait-term|wait-int|payload-exit)
    echo 'Failed to start exit.target: Unit exit.target not found.' >&2
    exit 1
    ;;
  repeated)
    kill -INT "$TEST_SUPERVISOR_PID"
    kill -INT "$TEST_SUPERVISOR_PID"
    kill -TERM "$TEST_SUPERVISOR_PID"
    exit 1
    ;;
  stalled-client) exec sleep 30 ;;
  stalled-manager|unreaped) exit 0 ;;
  *) exit 98 ;;
esac
EOF
chmod +x "$fixture/bin/systemctl"
export PATH="$fixture/bin:$PATH"

printf '[test] required shutdown unit files and manager load state\n'
verify_rootless_shutdown_unit_files || fail "complete unit set rejected"
verify_rootless_shutdown_units_loaded || fail "loaded units rejected"
mv "$SYSTEMD_UNIT_PATH/exit.target" "$fixture/exit.target"
if verify_rootless_shutdown_unit_files 2> "$fixture/error"; then
  fail "missing exit.target was accepted"
fi
mv "$fixture/exit.target" "$SYSTEMD_UNIT_PATH/exit.target"
if TEST_BAD_UNIT=exit.target verify_rootless_shutdown_units_loaded 2> "$fixture/error"; then
  fail "manager with missing exit.target was accepted"
fi

# The driver uses the production lifecycle functions and real children. Only
# systemctl and the kernel's cgroup files are simulated; no host units are used.
cat > "$fixture/driver" <<'EOF'
#!/usr/bin/env bash
set -eu
source "$1/scripts/image/rootless-linux-lifecycle.sh"
manager_cgroup="$TEST_FIXTURE"
printf 'populated 1\n' > "$manager_cgroup/cgroup.events"
exec {manager_kill_fd}> "$manager_cgroup/cgroup.kill"
kill_file="$manager_cgroup/cgroup.kill"
if [ "$TEST_MODE" = replaced-path ]; then
  mv "$kill_file" "$manager_cgroup/original.kill"
  printf 'unrelated-boundary\n' > "$kill_file"
  kill_file="$manager_cgroup/original.kill"
fi
sleep 30 >/dev/null 2>&1 &
manager_pid=$!
printf '%s\n' "$manager_pid" > "$TEST_FIXTURE/manager.pid"
export TEST_MANAGER_PID="$manager_pid" TEST_SUPERVISOR_PID="$BASHPID"
install_private_manager_cleanup

if [ "$TEST_MODE" = orphan ]; then
  kill "$manager_pid"
  wait "$manager_pid" || true
fi
if [ "$TEST_MODE" != graceful ] && [ "$TEST_MODE" != unreaped ]; then
  sleep 30 >/dev/null 2>&1 &
  descendant_pid=$!
  printf '%s\n' "$descendant_pid" > "$TEST_FIXTURE/descendant.pid"
  # Simulate the kernel reacting to a write on the original kill-file inode.
  (
    while [ ! -s "$kill_file" ]; do sleep 0.05; done
    kill -KILL "$manager_pid" "$descendant_pid" 2>/dev/null || true
    printf 'populated 0\n' > "$TEST_FIXTURE/cgroup.events"
  ) >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$TEST_FIXTURE/kernel.pid"
fi
case "$TEST_MODE" in
  interrupt) kill -INT "$BASHPID" ;;
  term) kill -TERM "$BASHPID" ;;
  wait-term|wait-int)
    signal=TERM
    [ "$TEST_MODE" != wait-int ] || signal=INT
    (sleep 0.2; kill -"$signal" "$TEST_SUPERVISOR_PID") &
    wait_for_agent bash -c 'echo "$$" > "$TEST_FIXTURE/payload.pid"; exec sleep 30'
    exit 99
    ;;
  payload-exit)
    set +e
    wait_for_agent bash -c 'read -r line; [ "$line" = terminal-input ] || exit 98; exit 23' <<< terminal-input
    exit "$?"
    ;;
esac
exit "$TEST_STATUS"
EOF

sleep 120 >/dev/null 2>&1 &
outside_pid=$!
printf '%s\n' "$outside_pid" > "$fixture/outside.pid"
for mode in graceful missing stalled-client stalled-manager repeated interrupt term orphan unreaped replaced-path wait-term wait-int payload-exit; do
  printf '[test] private manager cleanup: %s\n' "$mode"
  case_dir="$fixture/$mode"
  mkdir "$case_dir"
  expected=23
  case "$mode" in
    graceful) expected=0 ;;
    interrupt|wait-int) expected=130 ;;
    term|wait-term) expected=143 ;;
  esac
  started="$SECONDS"
  set +e
  TEST_FIXTURE="$case_dir" TEST_MODE="$mode" TEST_STATUS="$expected" \
    timeout --signal=KILL 12s bash "$fixture/driver" "$REPO_ROOT" > "$case_dir/output" 2>&1
  result=$?
  set -e
  [ "$result" = "$expected" ] || fail "$mode: expected status $expected, got $result"
  [ "$((SECONDS - started))" -le 8 ] || fail "$mode: cleanup exceeded deadline"
  kill -0 "$outside_pid" || fail "$mode: unrelated process was killed"
  if [ "$mode" = graceful ]; then
    [ ! -s "$case_dir/cgroup.kill" ] || fail "graceful exit should not force a cgroup kill"
  else
    kill_file="$case_dir/cgroup.kill"
    if [ "$mode" = replaced-path ]; then
      [ "$(cat "$kill_file")" = unrelated-boundary ] || fail "cleanup resolved a replaced kill path"
      kill_file="$case_dir/original.kill"
    fi
    [ "$(cat "$kill_file")" = 1 ] || fail "$mode: no scoped kill request"
    grep -q 'terminating its sandbox cgroup' "$case_dir/output" || fail "$mode: missing forced-shutdown diagnostic"
  fi
  if [ "$mode" = repeated ]; then
    [ "$(wc -l < "$case_dir/requests")" = 1 ] || fail "signals restarted cleanup"
  fi
  if [ "$mode" = unreaped ]; then
    grep -q 'without waiting' "$case_dir/output" || fail "unreapable child needs a diagnostic"
  fi
  # Reap/stop only the fixture's known children, including the deliberately
  # unreaped case. Keep the outside sentinel alive until the whole suite ends.
  for pid_file in "$case_dir"/*.pid; do
    read -r pid < "$pid_file"
    kill "$pid" 2>/dev/null || true
    rm -f "$pid_file"
  done
done
