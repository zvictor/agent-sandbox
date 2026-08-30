#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "[agent] rootless-linux session unavailable: $*" >&2
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

tool="${AGENT_ROOTLESS_LINUX_TOOL:-}"
[ -n "$tool" ] || fail "AGENT_ROOTLESS_LINUX_TOOL is not set"
[ -x "$tool" ] || fail "tool launcher is not executable: $tool"
[ "$(id -u)" != "0" ] || fail "the agent must run as an unprivileged user"
[ -n "${XDG_RUNTIME_DIR:-}" ] || fail "XDG_RUNTIME_DIR is not set"
[ -d "$XDG_RUNTIME_DIR" ] && [ -r "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ] && [ -x "$XDG_RUNTIME_DIR" ] \
  || fail "XDG_RUNTIME_DIR is not usable"

for command_name in bwrap systemctl systemd-run; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is not installed"
done
[ -x /lib/systemd/systemd ] || fail "the systemd user manager is not installed"
[ -d /example/systemd/user ] || fail "the immutable systemd user units are not installed"

# Keep this private manager independent from writable, persistent user unit
# state. The profile needs only systemd's immutable core user targets and
# transient units submitted through the manager API.
export SYSTEMD_UNIT_PATH=/example/systemd/user
export SYSTEMD_GENERATOR_PATH=
export SYSTEMD_ENVIRONMENT_GENERATOR_PATH=

bwrap_version="$(bwrap --version 2>/dev/null | awk '{ print $NF; exit }')"
case "$bwrap_version" in
  ""|*[!0-9.]*) fail "could not determine the Bubblewrap version" ;;
esac
if [ "$(printf '%s\n' 0.12.0 "$bwrap_version" | sort -V | head -n 1)" != "0.12.0" ]; then
  fail "Bubblewrap 0.12.0 or newer is required (found $bwrap_version)"
fi

effective_caps="$(awk '/^CapEff:/ { print $2; exit }' /proc/self/status)"
[ -n "$effective_caps" ] || fail "could not inspect effective capabilities"
[ -z "${effective_caps//0/}" ] || fail "the agent process must not have effective capabilities"

[ -f /sys/fs/cgroup/cgroup.controllers ] || fail "cgroup v2 is not mounted"
cgroup_path="$(awk -F: '$1 == "0" { print $3; exit }' /proc/self/cgroup)"
[ "$cgroup_path" = "/" ] || fail "a private cgroup namespace is required"
cgroup_root=/sys/fs/cgroup

cgroup_write_error=""
if ! cgroup_write_error="$(
  { printf '%s\n' "$$" > "$cgroup_root/cgroup.procs"; } 2>&1
)"; then
  mount_state="$(awk '$5 == "/sys/fs/cgroup" { line = $0 } END { print line }' /proc/self/mountinfo 2>/dev/null || true)"
  uid_map="$(awk '{ printf "%s%s", separator, $0; separator = ";" } END { print "" }' /proc/self/uid_map 2>/dev/null || true)"
  gid_map="$(awk '{ printf "%s%s", separator, $0; separator = ";" } END { print "" }' /proc/self/gid_map 2>/dev/null || true)"

  printf '[agent] rootless-linux cgroup probe: write-error=%s\n' "${cgroup_write_error:-unknown}" >&2
  printf '[agent] rootless-linux cgroup probe: identity=%s\n' "$(id 2>/dev/null || true)" >&2
  printf '[agent] rootless-linux cgroup probe: uid-map=%s\n' "${uid_map:-unknown}" >&2
  printf '[agent] rootless-linux cgroup probe: gid-map=%s\n' "${gid_map:-unknown}" >&2
  printf '[agent] rootless-linux cgroup probe: mount=%s\n' "${mount_state:-unknown}" >&2
  stat -c '[agent] rootless-linux cgroup probe: %n uid=%u gid=%g mode=%a' \
    "$cgroup_root" "$cgroup_root/cgroup.procs" "$cgroup_root/cgroup.subtree_control" \
    >&2 2>/dev/null || true
  printf '[agent] rootless-linux cgroup probe: controllers=%s\n' \
    "$(cat "$cgroup_root/cgroup.controllers" 2>/dev/null || true)" >&2
  fail "the container cgroup is not writable by the unprivileged session"
fi

controllers="$(cat "$cgroup_root/cgroup.controllers")"
for controller in cpu memory pids; do
  has_controller "$controllers" "$controller" \
    || fail "$controller is not delegated to the container"
done

session_suffix="$$"
supervisor_cgroup="$cgroup_root/session-supervisor-$session_suffix"
manager_cgroup="$cgroup_root/user-manager-$session_suffix"
mkdir "$supervisor_cgroup" "$manager_cgroup"

# The OCI init and this bootstrap initially occupy the delegated cgroup root.
# Move both into a sibling before enabling controllers for the private user
# manager. The agent itself is started below as a delegated transient service.
printf '1\n' > "$supervisor_cgroup/cgroup.procs"
printf '%s\n' "$$" > "$supervisor_cgroup/cgroup.procs"
printf '+cpu +memory +pids\n' > "$cgroup_root/cgroup.subtree_control"

(
  printf '%s\n' "$BASHPID" > "$manager_cgroup/cgroup.procs"
  exec /lib/systemd/systemd --user --unit=basic.target
) &
manager_pid=$!

stop_manager() {
  trap - EXIT
  if kill -0 "$manager_pid" >/dev/null 2>&1; then
    systemctl --user exit >/dev/null 2>&1 || kill "$manager_pid" >/dev/null 2>&1 || true
    wait "$manager_pid" >/dev/null 2>&1 || true
  fi
}
trap stop_manager EXIT

manager_ready=0
for _ in $(seq 1 200); do
  if systemctl --user show-environment >/dev/null 2>&1; then
    manager_ready=1
    break
  fi
  kill -0 "$manager_pid" >/dev/null 2>&1 \
    || fail "the private systemd user manager terminated during startup"
  sleep 0.05
done
[ "$manager_ready" = "1" ] || fail "the private systemd user manager did not become ready"

capability_probe='set -eu
cgroup_path="$(awk -F: '\''$1 == "0" { print $3; exit }'\'' /proc/self/cgroup)"
[ -n "$cgroup_path" ]
scope_path="/sys/fs/cgroup$cgroup_path"
controllers="$(cat "$scope_path/cgroup.controllers")"
for controller in cpu memory pids; do
  case " $controllers " in
    *" $controller "*) ;;
    *) exit 1 ;;
  esac
done
[ -w "$scope_path/cgroup.procs" ]
[ -w "$scope_path/cgroup.subtree_control" ]
payload_path="$scope_path/capability-payload.$$"
probe_path="$scope_path/capability-probe.$$"
mkdir "$payload_path"
printf '\''0\n'\'' > "$payload_path/cgroup.procs"
migrated_path="$(awk -F: '\''$1 == "0" { print $3; exit }'\'' /proc/self/cgroup)"
[ "$migrated_path" = "$cgroup_path/capability-payload.$$" ]
printf '\''+cpu +memory +pids\n'\'' > "$scope_path/cgroup.subtree_control"
mkdir "$probe_path"
printf 'max\n' > "$probe_path/cpu.max"
printf 'max\n' > "$probe_path/memory.max"
printf 'max\n' > "$probe_path/pids.max"
rmdir "$probe_path"
bwrap --unshare-user --ro-bind / / -- /bin/true'

if ! systemd-run --user --wait --collect --quiet \
  --service-type=exec \
  --property='Delegate=cpu memory pids' \
  --pipe -- \
  /bin/bash -c "$capability_probe"; then
  fail "the private user manager, delegated cgroup, or nested user namespace probe failed"
fi

case "${AGENT_ROOTLESS_LINUX_PROBE_ONLY:-0}" in
  0|"") ;;
  1) exit 0 ;;
  *) fail "AGENT_ROOTLESS_LINUX_PROBE_ONLY must be 0 or 1" ;;
esac

stdio_flag=--pipe
if [ -t 0 ] && [ -t 1 ]; then
  stdio_flag=--pty
fi

set +e
systemd-run --user --wait --collect --quiet \
  --service-type=exec \
  --property='Delegate=cpu memory pids' \
  --working-directory="$PWD" \
  "$stdio_flag" -- \
  "$tool" "$@"
status=$?
set -e

exit "$status"
