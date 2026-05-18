#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./remote-execution-lib.sh
source "$SCRIPT_DIR/remote-execution-lib.sh"

TEST_ATTR=${1:-}

if [[ $# -ne 1 || -z "$TEST_ATTR" ]]; then
  echo "usage: $0 <test-attr>" >&2
  echo "pass an explicit flake check attribute, e.g. checks.x86_64-linux.some-vm-test" >&2
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
NIX_BIN=/nix/var/nix/profiles/default/bin/nix
if [[ ! -x \$NIX_BIN ]]; then
  echo \"nix is missing after install step\" >&2
  exit 1
fi
cd /workspace
\$NIX_BIN --option build-users-group \"\" \
  --accept-flake-config --extra-experimental-features \"nix-command flakes\" \
  build -L \".#${TEST_ATTR}\"
"
remote_execution_success
