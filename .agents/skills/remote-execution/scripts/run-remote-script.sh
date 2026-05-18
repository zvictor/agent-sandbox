#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./remote-execution-lib.sh
source "$SCRIPT_DIR/remote-execution-lib.sh"

LOCAL_SCRIPT_PATH=${1:-}

if [[ $# -ne 1 || -z "$LOCAL_SCRIPT_PATH" ]]; then
  echo "usage: $0 <local-script-path>" >&2
  echo "pass a local shell script file to execute remotely from /workspace" >&2
  exit 64
fi

if [[ ! -f "$LOCAL_SCRIPT_PATH" ]]; then
  echo "local script not found: $LOCAL_SCRIPT_PATH" >&2
  exit 66
fi

remote_execution_init
remote_execution_announce_run_dir
trap remote_execution_cleanup EXIT INT TERM

remote_execution_require_prereqs
remote_execution_require_modern_cli
remote_execution_require_archive_tools
remote_execution_create_instance
remote_execution_wait_until_ready
remote_execution_ensure_nix
remote_execution_pack_workspace
remote_execution_upload_workspace
remote_execution_upload_and_run_local_script "$LOCAL_SCRIPT_PATH"
remote_execution_success
