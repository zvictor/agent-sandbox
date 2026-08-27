#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "[fail] $*" >&2
  exit 1
}

process_status_field() {
  local pid="$1"
  local field="$2"

  awk -v field="$field" '$1 == field ":" { print $2; exit }' "/proc/$pid/status" 2>/dev/null || true
}

zombie_count() {
  local status_file=""
  local state=""
  local count="0"

  for status_file in /proc/[0-9]*/status; do
    [ -r "$status_file" ] || continue
    state="$(awk '$1 == "State:" { print $2; exit }' "$status_file" 2>/dev/null || true)"
    if [ "$state" = "Z" ]; then
      count=$((count + 1))
    fi
  done

  printf '%s\n' "$count"
}

wait_for_reparenting() {
  local child_pid="$1"
  local step="0"
  local parent_pid=""

  while [ "$step" -lt 200 ]; do
    [ -e "/proc/$child_pid/status" ] || fail "descendant $child_pid exited before reparenting was observed"
    parent_pid="$(process_status_field "$child_pid" PPid)"
    if [ "$parent_pid" = "1" ]; then
      return 0
    fi
    sleep 0.01
    step=$((step + 1))
  done

  fail "descendant $child_pid was not reparented to PID 1"
}

wait_for_reaping() {
  local child_pid="$1"
  local baseline="$2"
  local step="0"
  local current=""

  while [ "$step" -lt 400 ]; do
    current="$(zombie_count)"
    if [ ! -e "/proc/$child_pid/status" ] && [ "$current" -eq "$baseline" ]; then
      return 0
    fi
    sleep 0.01
    step=$((step + 1))
  done

  current="$(zombie_count)"
  fail "PID 1 did not reap descendant $child_pid (baseline=$baseline current=$current)"
}

run_cycle() {
  local cycle="$1"
  local baseline="$2"
  local child_file="/tmp/agent-pid1-child-$$-$cycle"
  local parent_pid=""
  local child_pid=""
  local step="0"

  rm -f "$child_file"
  bash -c 'sleep 1 & printf "%s\n" "$!" > "$1"; wait' bash "$child_file" &
  parent_pid="$!"

  while [ "$step" -lt 200 ]; do
    [ -s "$child_file" ] && break
    kill -0 "$parent_pid" 2>/dev/null || fail "parent $parent_pid exited before publishing its descendant"
    sleep 0.01
    step=$((step + 1))
  done
  [ -s "$child_file" ] || fail "parent $parent_pid did not publish its descendant"

  child_pid="$(cat "$child_file")"
  case "$child_pid" in
    ''|*[!0-9]*) fail "parent $parent_pid published an invalid descendant PID" ;;
  esac

  kill -KILL "$parent_pid"
  wait "$parent_pid" 2>/dev/null || true
  wait_for_reparenting "$child_pid"
  wait_for_reaping "$child_pid" "$baseline"
  rm -f "$child_file"
}

main() {
  local cycles="${AGENT_PID1_REAPER_CYCLES:-12}"
  local baseline=""
  local final=""
  local cycle="1"
  local pid1_command=""

  case "$cycles" in
    ''|*[!0-9]*|0) fail "AGENT_PID1_REAPER_CYCLES must be a positive integer" ;;
  esac
  [ "$$" -ne 1 ] || fail "probe is PID 1; the runtime init reaper is missing"

  pid1_command="$(tr '\0' ' ' < /proc/1/cmdline 2>/dev/null || true)"
  [ -n "$pid1_command" ] || fail "could not identify PID 1"
  baseline="$(zombie_count)"

  while [ "$cycle" -le "$cycles" ]; do
    run_cycle "$cycle" "$baseline"
    cycle=$((cycle + 1))
  done

  final="$(zombie_count)"
  [ "$final" -eq "$baseline" ] || fail "zombie count accumulated (baseline=$baseline final=$final)"
  printf '[pass] PID 1 reaped orphaned descendants across %s cycles (baseline=%s final=%s pid1=%s)\n' \
    "$cycles" "$baseline" "$final" "$pid1_command"
}

main "$@"
