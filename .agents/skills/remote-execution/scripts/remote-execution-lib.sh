#!/usr/bin/env bash

set -euo pipefail

remote_execution_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

remote_execution_init() {
  NSC_MACHINE=${NSC_MACHINE:-"1x2"}
  NSC_DURATION=${NSC_DURATION:-"30m"}
  NSC_NIX_CACHE_TAG=${NSC_NIX_CACHE_TAG:-"nix-store"}
  NSC_DEBUG=${NSC_DEBUG:-"0"}
  NSC_TRACE=${NSC_TRACE:-"0"}
  NSC_LOG_DIR=${NSC_LOG_DIR:-""}
  NSC_HEARTBEAT_SECONDS=${NSC_HEARTBEAT_SECONDS:-"30"}

  if [[ -n "$NSC_LOG_DIR" ]]; then
    RUN_DIR=$NSC_LOG_DIR
    mkdir -p "$RUN_DIR"
  else
    RUN_DIR=$(mktemp -d -t remote-execution.XXXXXX)
  fi

  INFRA_LOG="$RUN_DIR/infra.log"
  EXECUTION_LOG="$RUN_DIR/execution.txt"
  SUMMARY_FILE="$RUN_DIR/summary.txt"
  INSTANCE_ID_FILE="$RUN_DIR/instance-id"
  ARCHIVE_FILE="$RUN_DIR/workspace.tar.gz"
  REMOTE_ARCHIVE_PATH="/tmp/remote-execution-workspace.tar.gz"
  REMOTE_EXECUTION_SCRIPT_FILE="$RUN_DIR/remote-execution.sh"
  HEARTBEAT_MARKER_FILE="$RUN_DIR/heartbeat-seen"

  : >"$INFRA_LOG"
  : >"$EXECUTION_LOG"
  : >"$SUMMARY_FILE"
  rm -f "$HEARTBEAT_MARKER_FILE"

  INSTANCE_ID=""
  REMOTE_EXECUTION_PHASE="init"
  REMOTE_EXECUTION_LAST_SUCCESSFUL_PHASE=""
  REMOTE_EXECUTION_STATUS="running"
  REMOTE_EXECUTION_STARTED_AT=$(remote_execution_now_iso)
  REMOTE_EXECUTION_STARTED_AT_EPOCH=$(date -u +%s)
  REMOTE_EXECUTION_FINISHED_AT=""
  REMOTE_EXECUTION_FINISHED_AT_EPOCH=""
  REMOTE_EXECUTION_STREAM_STARTED=0
  REMOTE_EXECUTION_STREAM_FINISHED=0
  REMOTE_EXECUTION_STREAM_STARTED_AT=""
  REMOTE_EXECUTION_STREAM_FINISHED_AT=""
  REMOTE_EXECUTION_STREAM_EXIT_CODE=""
  REMOTE_EXECUTION_REMOTE_CWD=""
  remote_execution_refresh_summary
}

remote_execution_note() {
  printf '%s\n' "$*"
}

remote_execution_debug_enabled() {
  [[ "$NSC_DEBUG" != "0" ]]
}

remote_execution_filter_nsc_noise() {
  sed '/^warning: Failed to write token cache: open \/var\/run\/nsc\/token\.cache: permission denied$/d'
}

remote_execution_record_command() {
  local phase=$1
  shift

  printf '\n[%s] $' "$phase" >>"$INFRA_LOG"
  printf ' %q' "$@" >>"$INFRA_LOG"
  printf '\n' >>"$INFRA_LOG"
}

remote_execution_phase_start() {
  REMOTE_EXECUTION_PHASE=$1
  remote_execution_refresh_summary
}

remote_execution_phase_complete() {
  REMOTE_EXECUTION_LAST_SUCCESSFUL_PHASE=$1
  remote_execution_refresh_summary
}

remote_execution_refresh_summary() {
  local duration_seconds=""
  local heartbeat_seen=0
  local execution_log_bytes=0
  local execution_silent=1

  if [[ -f "$HEARTBEAT_MARKER_FILE" ]]; then
    heartbeat_seen=1
  fi

  if [[ -f "$EXECUTION_LOG" ]]; then
    execution_log_bytes=$(wc -c <"$EXECUTION_LOG" 2>/dev/null || echo 0)
  fi

  if [[ "$execution_log_bytes" -gt 0 ]]; then
    execution_silent=0
  fi

  if [[ -n "${REMOTE_EXECUTION_FINISHED_AT_EPOCH:-}" ]]; then
    duration_seconds=$((REMOTE_EXECUTION_FINISHED_AT_EPOCH - REMOTE_EXECUTION_STARTED_AT_EPOCH))
  else
    duration_seconds=$(( $(date -u +%s) - REMOTE_EXECUTION_STARTED_AT_EPOCH ))
  fi

  cat >"$SUMMARY_FILE" <<EOF
status=$REMOTE_EXECUTION_STATUS
phase=$REMOTE_EXECUTION_PHASE
last_successful_phase=${REMOTE_EXECUTION_LAST_SUCCESSFUL_PHASE:-}
heartbeat_seen=$heartbeat_seen
started_at=$REMOTE_EXECUTION_STARTED_AT
finished_at=${REMOTE_EXECUTION_FINISHED_AT:-}
duration_seconds=$duration_seconds
run_dir=$RUN_DIR
instance_id=${INSTANCE_ID:-}
infra_log=$INFRA_LOG
execution_log=$EXECUTION_LOG
execution_script=$REMOTE_EXECUTION_SCRIPT_FILE
remote_cwd=${REMOTE_EXECUTION_REMOTE_CWD:-}
trace_enabled=$([[ "$NSC_TRACE" != "0" ]] && printf 1 || printf 0)
execution_started=$REMOTE_EXECUTION_STREAM_STARTED
execution_finished=$REMOTE_EXECUTION_STREAM_FINISHED
execution_started_at=${REMOTE_EXECUTION_STREAM_STARTED_AT:-}
execution_finished_at=${REMOTE_EXECUTION_STREAM_FINISHED_AT:-}
execution_exit_code=${REMOTE_EXECUTION_STREAM_EXIT_CODE:-}
execution_log_bytes=$execution_log_bytes
execution_silent=$execution_silent
EOF
}

remote_execution_announce_run_dir() {
  printf 'Run directory: %s\n' "$RUN_DIR"
  printf 'Summary: %s\n' "$SUMMARY_FILE"
}

remote_execution_start_quiet_heartbeat() {
  local phase=$1
  local watched_file=$2
  local target_pid=$3

  (
    local last_size=0
    local current_size=0
    local quiet_for=0

    last_size=$(wc -c <"$watched_file" 2>/dev/null || echo 0)

    while kill -0 "$target_pid" 2>/dev/null; do
      sleep "$NSC_HEARTBEAT_SECONDS"

      if ! kill -0 "$target_pid" 2>/dev/null; then
        break
      fi

      current_size=$(wc -c <"$watched_file" 2>/dev/null || echo 0)

      if [[ "$current_size" -eq "$last_size" ]]; then
        quiet_for=$((quiet_for + NSC_HEARTBEAT_SECONDS))
        : >"$HEARTBEAT_MARKER_FILE"
        remote_execution_refresh_summary
        printf '[%s] still running (%ss without output)\n' "$phase" "$quiet_for"
        printf '[%s-heartbeat] still running (%ss without output)\n' "$phase" "$quiet_for" >>"$INFRA_LOG"
      else
        last_size=$current_size
        quiet_for=0
      fi
    done
  ) &
  REMOTE_EXECUTION_HEARTBEAT_PID=$!
}

remote_execution_run_infra() {
  local phase=$1
  shift
  local output_pid
  local heartbeat_pid
  local status

  remote_execution_record_command "$phase" "$@"

  if remote_execution_debug_enabled; then
    (
      "$@" 2>&1 | remote_execution_filter_nsc_noise | tee -a "$INFRA_LOG"
      exit "${PIPESTATUS[0]}"
    ) &
  else
    (
      "$@" 2>&1 | remote_execution_filter_nsc_noise >>"$INFRA_LOG"
      exit "${PIPESTATUS[0]}"
    ) &
  fi
  output_pid=$!

  remote_execution_start_quiet_heartbeat "$phase" "$INFRA_LOG" "$output_pid"
  heartbeat_pid=$REMOTE_EXECUTION_HEARTBEAT_PID

  wait "$output_pid"
  status=$?
  kill "$heartbeat_pid" 2>/dev/null || true
  wait "$heartbeat_pid" 2>/dev/null || true
  return "$status"
}

remote_execution_run_remote_infra() {
  local phase=$1
  local script=$2
  local output_pid
  local heartbeat_pid
  local status

  printf '\n[%s] remote script\n%s\n' "$phase" "$script" >>"$INFRA_LOG"

  if remote_execution_debug_enabled; then
    (
      { printf '%s\n' "$script"; } | nsc ssh --disable-pty "$INSTANCE_ID" -- bash -s -- 2>&1 | remote_execution_filter_nsc_noise | tee -a "$INFRA_LOG"
      exit "${PIPESTATUS[1]}"
    ) &
  else
    (
      { printf '%s\n' "$script"; } | nsc ssh --disable-pty "$INSTANCE_ID" -- bash -s -- 2>&1 | remote_execution_filter_nsc_noise >>"$INFRA_LOG"
      exit "${PIPESTATUS[1]}"
    ) &
  fi
  output_pid=$!

  remote_execution_start_quiet_heartbeat "$phase" "$INFRA_LOG" "$output_pid"
  heartbeat_pid=$REMOTE_EXECUTION_HEARTBEAT_PID

  wait "$output_pid"
  status=$?
  kill "$heartbeat_pid" 2>/dev/null || true
  wait "$heartbeat_pid" 2>/dev/null || true
  return "$status"
}

remote_execution_run_remote_stream() {
  local phase=$1
  local script=$2
  local effective_script
  local output_pid
  local heartbeat_pid
  local status

  REMOTE_EXECUTION_PHASE=$phase
  REMOTE_EXECUTION_STREAM_STARTED=1
  REMOTE_EXECUTION_STREAM_FINISHED=0
  REMOTE_EXECUTION_STREAM_STARTED_AT=$(remote_execution_now_iso)
  REMOTE_EXECUTION_STREAM_FINISHED_AT=""
  REMOTE_EXECUTION_STREAM_EXIT_CODE=""

  if [[ "$NSC_TRACE" != "0" ]]; then
    effective_script=$(printf 'set -x\n%s\n' "$script")
  else
    effective_script=$script
  fi

  printf '%s\n' "$effective_script" >"$REMOTE_EXECUTION_SCRIPT_FILE"
  printf '\n[%s] execution script saved to %s\n' "$phase" "$REMOTE_EXECUTION_SCRIPT_FILE" >>"$INFRA_LOG"
  remote_execution_refresh_summary

  : >"$EXECUTION_LOG"

  (
    { printf '%s\n' "$effective_script"; } | nsc ssh --disable-pty "$INSTANCE_ID" -- bash -s -- 2>&1 | remote_execution_filter_nsc_noise | tee -a "$EXECUTION_LOG"
    exit "${PIPESTATUS[1]}"
  ) &
  output_pid=$!

  remote_execution_start_quiet_heartbeat "$phase" "$EXECUTION_LOG" "$output_pid"
  heartbeat_pid=$REMOTE_EXECUTION_HEARTBEAT_PID

  wait "$output_pid"
  status=$?
  kill "$heartbeat_pid" 2>/dev/null || true
  wait "$heartbeat_pid" 2>/dev/null || true
  REMOTE_EXECUTION_STREAM_FINISHED=1
  REMOTE_EXECUTION_STREAM_FINISHED_AT=$(remote_execution_now_iso)
  REMOTE_EXECUTION_STREAM_EXIT_CODE=$status
  remote_execution_refresh_summary
  return "$status"
}

remote_execution_require_prereqs() {
  if ! command -v nsc >/dev/null 2>&1; then
    echo "nsc is required but not on PATH" >&2
    echo "install the Namespace CLI in the agent environment (Nix package: namespace-cli)" >&2
    exit 127
  fi

  if ! nsc auth check-login >/dev/null 2>&1; then
    echo "nsc is installed but not authenticated. Run 'nsc auth login' first." >&2
    exit 1
  fi
}

remote_execution_require_archive_tools() {
  if ! command -v tar >/dev/null 2>&1; then
    echo "tar is required locally. Provide GNU tar (package name: gnutar) and retry." >&2
    exit 127
  fi

  if ! command -v gzip >/dev/null 2>&1; then
    echo "gzip is required locally. Provide gzip and retry." >&2
    exit 127
  fi
}

remote_execution_require_modern_cli() {
  if ! nsc instance upload --help >/dev/null 2>&1; then
    echo "the installed nsc does not support 'nsc instance upload'" >&2
    echo "install a newer Namespace CLI before using this skill" >&2
    exit 1
  fi
}

remote_execution_compute_warm_scope() {
  local repo_slug

  if [[ -n "${NSC_NIX_CACHE_SCOPE:-}" ]]; then
    printf '%s\n' "$NSC_NIX_CACHE_SCOPE"
    return 0
  fi

  repo_slug=$(basename "$PWD" | tr -cs 'A-Za-z0-9._-' '-')

  if [[ -f flake.lock ]]; then
    cksum flake.lock | awk -v repo="$repo_slug" '{ printf "%s-flake-lock-%s-%s\n", repo, $1, $2 }'
    return 0
  fi

  if [[ -f flake.nix ]]; then
    cksum flake.nix | awk -v repo="$repo_slug" '{ printf "%s-flake-nix-%s-%s\n", repo, $1, $2 }'
    return 0
  fi

  printf '%s\n' "${repo_slug}-global"
}

remote_execution_fail() {
  local phase=$1
  local exit_code=${2:-1}

  REMOTE_EXECUTION_PHASE=$phase
  REMOTE_EXECUTION_STATUS="failed"
  REMOTE_EXECUTION_FINISHED_AT=$(remote_execution_now_iso)
  REMOTE_EXECUTION_FINISHED_AT_EPOCH=$(date -u +%s)
  remote_execution_refresh_summary
  printf 'exit_code=%s\n' "$exit_code" >>"$SUMMARY_FILE"

  printf 'Remote execution failed during phase: %s\n' "$phase" >&2
  printf 'Run directory: %s\n' "$RUN_DIR" >&2
  printf 'Summary: %s\n' "$SUMMARY_FILE" >&2
  printf 'Infra log: %s\n' "$INFRA_LOG" >&2

  if [[ -s "$EXECUTION_LOG" ]]; then
    printf 'Execution log: %s\n' "$EXECUTION_LOG" >&2
    printf '\nExecution output tail:\n' >&2
    tail -n 80 "$EXECUTION_LOG" >&2
  fi

  if [[ -s "$INFRA_LOG" ]]; then
    printf '\nInfra log tail:\n' >&2
    tail -n 40 "$INFRA_LOG" >&2
  fi

  exit "$exit_code"
}

remote_execution_mark_success() {
  local label=$1
  local execution_log_bytes=0

  REMOTE_EXECUTION_STATUS="ok"
  REMOTE_EXECUTION_FINISHED_AT=$(remote_execution_now_iso)
  REMOTE_EXECUTION_FINISHED_AT_EPOCH=$(date -u +%s)
  remote_execution_refresh_summary
  printf 'exit_code=0\n' >>"$SUMMARY_FILE"

  if [[ -f "$EXECUTION_LOG" ]]; then
    execution_log_bytes=$(wc -c <"$EXECUTION_LOG" 2>/dev/null || echo 0)
  fi

  printf '%s\n' "$label"
  printf 'Run directory: %s\n' "$RUN_DIR"
  printf 'Summary: %s\n' "$SUMMARY_FILE"
  if [[ "$REMOTE_EXECUTION_STREAM_STARTED" = "1" && "$execution_log_bytes" -eq 0 ]]; then
    printf 'Execution output: remote execution completed successfully with no stdout/stderr\n'
  elif [[ -s "$EXECUTION_LOG" ]]; then
    printf 'Execution log: %s\n' "$EXECUTION_LOG"
  fi
  printf 'Infra log: %s\n' "$INFRA_LOG"
}

remote_execution_success() {
  remote_execution_mark_success "Execution succeeded."
}

remote_execution_cleanup() {
  local status=$?

  if [[ -n "${INSTANCE_ID:-}" ]]; then
    remote_execution_note "→ Destroying instance $INSTANCE_ID..."
    remote_execution_run_infra "teardown" nsc destroy --force "$INSTANCE_ID" || true
    INSTANCE_ID=""
  fi

  rm -f "$INSTANCE_ID_FILE" "$ARCHIVE_FILE"

  return "$status"
}

remote_execution_wait_for_shell() {
  local attempt output

  for attempt in $(seq 1 40); do
    if output=$(nsc ssh --disable-pty "$INSTANCE_ID" -- true 2>&1 | remote_execution_filter_nsc_noise); then
      printf '\n[ssh-ready] attempt=%s\n%s\n' "$attempt" "$output" >>"$INFRA_LOG"
      return 0
    fi

    printf '\n[ssh-ready] attempt=%s\n%s\n' "$attempt" "$output" >>"$INFRA_LOG"

    if printf '%s\n' "$output" | grep -qiE 'FailedPrecondition|failed to start'; then
      printf '%s\n' "$output" >&2
      return 1
    fi

    sleep 3
  done

  echo "Timed out waiting for instance $INSTANCE_ID to accept nsc ssh." >&2
  return 124
}

remote_execution_create_instance() {
  remote_execution_phase_start "instance-create"
  remote_execution_note "→ Creating ephemeral instance (shape: $NSC_MACHINE, duration: $NSC_DURATION)..."

  if remote_execution_run_infra \
    "instance-create" \
    nsc create \
      --bare \
      --machine_type "$NSC_MACHINE" \
      --duration "$NSC_DURATION" \
      --volume "cache:$NSC_NIX_CACHE_TAG:/nix:50gb" \
      --purpose "Remote execution" \
      --cidfile "$INSTANCE_ID_FILE"; then
    :
  else
    local status=$?
    remote_execution_fail "instance-create" "$status"
  fi

  INSTANCE_ID=$(cat "$INSTANCE_ID_FILE")
  remote_execution_refresh_summary
  remote_execution_note "→ Instance: $INSTANCE_ID"
  remote_execution_phase_complete "instance-create"
}

remote_execution_wait_until_ready() {
  remote_execution_phase_start "ssh-ready"
  remote_execution_note "→ Waiting for remote shell..."

  if remote_execution_wait_for_shell; then
    :
  else
    local status=$?
    remote_execution_fail "ssh-ready" "$status"
  fi
  remote_execution_phase_complete "ssh-ready"
}

remote_execution_ensure_nix() {
  remote_execution_phase_start "nix-bootstrap"
  remote_execution_note "→ Ensuring Nix is installed..."

  if remote_execution_run_remote_infra "nix-bootstrap" "
set -euo pipefail
NIX_BIN=/nix/var/nix/profiles/default/bin/nix
if [[ -x \$NIX_BIN ]]; then
  echo \"Nix found in cache, skipping install.\"
else
  echo \"Installing Nix (first run - will be cached for future runs)...\"
  curl -fsSL https://install.determinate.systems/nix \
    | sh -s -- install linux --determinate --init none --no-confirm
fi
"; then
    :
  else
    local status=$?
    remote_execution_fail "nix-bootstrap" "$status"
  fi
  remote_execution_phase_complete "nix-bootstrap"
}

remote_execution_pack_workspace() {
  remote_execution_phase_start "archive"
  remote_execution_note "→ Creating workspace archive..."

  if remote_execution_run_infra \
    "archive" \
    tar -czf "$ARCHIVE_FILE" \
      --exclude=.git \
      --exclude=result \
      --exclude=.direnv \
      --exclude=.agent-sandbox-codex-ssh \
      .; then
    :
  else
    local status=$?
    remote_execution_fail "archive" "$status"
  fi
  remote_execution_phase_complete "archive"
}

remote_execution_upload_file() {
  local phase=$1
  local local_path=$2
  local remote_path=$3

  if remote_execution_run_infra \
    "$phase" \
    nsc instance upload "$INSTANCE_ID" "$local_path" "$remote_path"; then
    :
  else
    local status=$?
    remote_execution_fail "$phase" "$status"
  fi
}

remote_execution_upload_workspace() {
  remote_execution_phase_start "upload"
  remote_execution_note "→ Uploading workspace..."

  remote_execution_upload_file "upload" "$ARCHIVE_FILE" "$REMOTE_ARCHIVE_PATH"

  if remote_execution_run_remote_infra "upload-unpack" "
set -euo pipefail
rm -rf /workspace
mkdir -p /workspace
tar -xzf \"$REMOTE_ARCHIVE_PATH\" -C /workspace
rm -f \"$REMOTE_ARCHIVE_PATH\"
"; then
    :
  else
    local status=$?
    remote_execution_fail "upload-unpack" "$status"
  fi
  remote_execution_phase_complete "upload-unpack"
}

remote_execution_upload_and_run_local_script() {
  local local_script_path=$1
  local remote_script_path="/tmp/remote-execution-input.sh"

  remote_execution_phase_start "upload-script"
  remote_execution_note "→ Uploading script..."
  remote_execution_upload_file "upload-script" "$local_script_path" "$remote_script_path"
  remote_execution_phase_complete "upload-script"

  remote_execution_run_workspace_script "
set -euo pipefail
export PATH=\"/nix/var/nix/profiles/default/bin:\$PATH\"
cd /workspace
bash \"$remote_script_path\"
"
}

remote_execution_run_workspace_script() {
  local script=$1

  remote_execution_phase_start "execution"
  REMOTE_EXECUTION_REMOTE_CWD="/workspace"
  remote_execution_note "→ Running remote execution..."

  if remote_execution_run_remote_stream "execution" "$script"; then
    :
  else
    local status=$?
    remote_execution_fail "execution" "$status"
  fi
  remote_execution_phase_complete "execution"
}
