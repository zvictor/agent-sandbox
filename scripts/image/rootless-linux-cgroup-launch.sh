#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "[agent] rootless-linux delegated cgroup unavailable: $*" >&2
  exit 1
}

has_controller() {
  local controllers="$1"
  local expected="$2"

  case " $controllers " in
    *" $expected "*) return 0 ;;
    *) return 1 ;;
  esac
}

[ "$#" -gt 0 ] || fail "no agent command was supplied"
[ "$(id -u)" != "0" ] || fail "the agent must run as an unprivileged user"

cgroup_path="$(awk -F: '$1 == "0" { print $3; exit }' /proc/self/cgroup)"
[ -n "$cgroup_path" ] || fail "could not resolve the delegated scope"
scope_path="/sys/fs/cgroup$cgroup_path"
[ -w "$scope_path/cgroup.procs" ] \
  || fail "delegated scope cgroup.procs is not writable: $scope_path/cgroup.procs"
[ -w "$scope_path/cgroup.subtree_control" ] \
  || fail "delegated scope cgroup.subtree_control is not writable: $scope_path/cgroup.subtree_control"

controllers="$(cat "$scope_path/cgroup.controllers")" \
  || fail "could not read the delegated scope controllers"
for controller in cpu memory pids; do
  has_controller "$controllers" "$controller" \
    || fail "$controller is not available to the delegated scope"
done

payload_name="agent-payload-$$"
payload_path="$scope_path/$payload_name"
mkdir "$payload_path" || fail "could not create the agent payload cgroup"
printf '0\n' > "$payload_path/cgroup.procs" \
  || fail "could not move the agent launcher below the delegated scope"

migrated_path="$(awk -F: '$1 == "0" { print $3; exit }' /proc/self/cgroup)"
[ "$migrated_path" = "$cgroup_path/$payload_name" ] \
  || fail "the agent launcher did not enter its payload cgroup (found: ${migrated_path:-unknown})"

remaining_pids="$(cat "$scope_path/cgroup.procs")" \
  || fail "could not verify the delegated scope population"
[ -z "$remaining_pids" ] \
  || fail "the delegated scope still contains processes: $remaining_pids"

printf '+cpu +memory +pids\n' > "$scope_path/cgroup.subtree_control" \
  || fail "could not activate CPU, memory, and PID controllers"
active_controllers="$(cat "$scope_path/cgroup.subtree_control")" \
  || fail "could not verify the active delegated controllers"
for controller in cpu memory pids; do
  has_controller "$active_controllers" "$controller" \
    || fail "$controller was not activated below the delegated scope"
done

for control_file in cpu.max memory.max pids.max; do
  [ -w "$payload_path/$control_file" ] \
    || fail "the agent payload lacks writable $control_file"
done

# This is a generic agent-sandbox boundary receipt, not authority. The path is
# already discoverable through procfs and remains writable only because the
# private user manager delegated this transient scope to the session user.
export AGENT_DELEGATED_CGROUP="$scope_path"

exec "$@"
