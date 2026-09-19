#!/usr/bin/env bash
# Sourced by the rootless entrypoint. No host manager or PID-wide kill commands.

verify_rootless_shutdown_unit_files() {
  local unit
  for unit in basic.target exit.target systemd-exit.service shutdown.target; do
    if [ ! -r "$SYSTEMD_UNIT_PATH/$unit" ]; then
      echo "[agent] rootless-linux shutdown unit is missing or unreadable: $SYSTEMD_UNIT_PATH/$unit" >&2
      return 1
    fi
  done
}

verify_rootless_shutdown_units_loaded() {
  local unit state
  for unit in basic.target exit.target systemd-exit.service shutdown.target; do
    if ! state="$(timeout --signal=KILL 5s systemctl --user show --property=LoadState --value "$unit")" || [ "$state" != loaded ]; then
      echo "[agent] private user manager cannot load $unit from $SYSTEMD_UNIT_PATH (state: ${state:-unavailable})" >&2
      return 1
    fi
  done
}

private_manager_populated() {
  local key value
  # Missing accounting is not evidence that the subtree is empty.
  [ -r "$manager_cgroup/cgroup.events" ] || return 0
  while read -r key value; do
    if [ "$key" = populated ]; then
      [ "$value" = 1 ]
      return
    fi
  done < "$manager_cgroup/cgroup.events"
  return 0
}

install_private_manager_cleanup() {
  trap 'stop_private_user_manager "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

wait_for_agent() {
  # Keep the terminal's stdin: asynchronous shell commands otherwise get
  # /dev/null. Restore signals which Bash ignores for asynchronous children.
  # Unlike a foreground external command, the wait builtin is interruptible
  # by our traps, so teardown can start even if the payload never returns.
  env --default-signal=INT,QUIT "$@" <&0 &
  wait "$!"
}

stop_private_user_manager() {
  local payload_status="$1" deadline=$((SECONDS + 5)) request_failed=0
  trap - EXIT
  # Repeated Ctrl+C must neither restart nor interrupt the cleanup deadline.
  trap '' INT TERM HUP

  if kill -0 "$manager_pid" 2>/dev/null; then
    # SIGTERM/SIGINT also try exit.target; they cannot recover a missing unit.
    # Bound the client too, in case the manager's bus is unresponsive.
    timeout --signal=KILL 5s systemctl --user exit || request_failed=1
  fi
  if [ "$request_failed" = 0 ]; then
    while private_manager_populated && [ "$SECONDS" -lt "$deadline" ]; do
      sleep 0.1
    done
  fi

  if private_manager_populated; then
    echo "[agent] private user manager shutdown did not complete; terminating its sandbox cgroup" >&2
    verify_rootless_shutdown_unit_files || true
    # This descriptor was opened on our newly created, private manager subtree
    # before spawning it. It cannot resolve to a replaced path or a reused PID.
    # PID 1 and the entrypoint are in a sibling cgroup and are not killed here.
    if ! printf '1\n' >&"$manager_kill_fd"; then
      echo "[agent] could not kill the private manager cgroup; leaving remaining processes to container teardown" >&2
    fi
    deadline=$((SECONDS + 1))
    while private_manager_populated && [ "$SECONDS" -lt "$deadline" ]; do
      sleep 0.1
    done
    if private_manager_populated; then
      echo "[agent] private manager cgroup still populated after SIGKILL; continuing container teardown without waiting" >&2
    fi
  fi

  # Even after SIGKILL, a process in uninterruptible sleep need not exit yet.
  # Reap only when it has already exited; never introduce another blocking wait.
  if ! kill -0 "$manager_pid" 2>/dev/null; then
    wait "$manager_pid" 2>/dev/null || true
  fi
  exec {manager_kill_fd}>&-
  exit "$payload_status"
}
