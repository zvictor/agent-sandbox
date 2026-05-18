#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./remote-execution-lib.sh
source "$SCRIPT_DIR/remote-execution-lib.sh"

REMOTE_COMMAND=${1:-}

if [[ $# -ne 1 || -z "$REMOTE_COMMAND" ]]; then
  echo "usage: $0 '<shell-command>'" >&2
  echo "pass a single remote shell snippet, e.g. $0 'pwd && ls -la'" >&2
  exit 64
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
remote_execution_run_workspace_script "
set -euo pipefail
export PATH=\"/nix/var/nix/profiles/default/bin:\$PATH\"
cd /workspace
$REMOTE_COMMAND
"
remote_execution_success
