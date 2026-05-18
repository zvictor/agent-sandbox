#!/usr/bin/env bash
# Warms the Nix cache volume so that run-remote-test.sh skips the Nix install step
# on all subsequent runs. Run once after workspace setup, or whenever nixpkgs is updated.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./remote-execution-lib.sh
source "$SCRIPT_DIR/remote-execution-lib.sh"

NSC_DURATION=${NSC_DURATION:-"15m"}
NSC_NIX_CACHE_FORCE=${NSC_NIX_CACHE_FORCE:-"0"}
WARM_SCOPE=$(remote_execution_compute_warm_scope)
WARM_RESULT="warmed"

remote_execution_init
remote_execution_announce_run_dir
trap remote_execution_cleanup EXIT INT TERM

remote_execution_require_prereqs
remote_execution_create_instance
remote_execution_wait_until_ready

remote_execution_phase_start "nix-cache-warm"
echo "→ Installing Nix into cache volume '$NSC_NIX_CACHE_TAG'..."
echo "→ Warm scope: $WARM_SCOPE"
if remote_execution_run_remote_infra "nix-cache-warm" "
set -euo pipefail
NIX_BIN=/nix/var/nix/profiles/default/bin/nix
WARM_ROOT=/nix/.remote-execution-cache-warm
READY_MARKER=\"\$WARM_ROOT/${WARM_SCOPE}.ready\"
if [[ ! -x \$NIX_BIN ]]; then
  curl -fsSL https://install.determinate.systems/nix \
    | sh -s -- install linux --determinate --init none --no-confirm
fi
if [[ \"${NSC_NIX_CACHE_FORCE}\" != \"1\" && -f \$READY_MARKER ]]; then
  echo \"Cache already warm for scope: ${WARM_SCOPE}\"
  exit 0
fi
echo \"Pre-fetching nixpkgs...\"
\$NIX_BIN --option build-users-group \"\" \
  --accept-flake-config --extra-experimental-features \"nix-command flakes\" \
  flake metadata \"github:nixos/nixpkgs/nixos-unstable\" --json > /dev/null
mkdir -p \"\$WARM_ROOT\"
printf '%s\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" > \"\$READY_MARKER\"
echo \"Cache is ready.\"
"; then
  :
else
  status=$?
  remote_execution_fail "nix-cache-warm" "$status"
fi

remote_execution_phase_complete "nix-cache-warm"
if grep -q "Cache already warm for scope: ${WARM_SCOPE}" "$INFRA_LOG"; then
  WARM_RESULT="reused"
fi

printf 'cache_tag=%s\n' "$NSC_NIX_CACHE_TAG" >>"$SUMMARY_FILE"
printf 'warm_scope=%s\n' "$WARM_SCOPE" >>"$SUMMARY_FILE"
printf 'warm_result=%s\n' "$WARM_RESULT" >>"$SUMMARY_FILE"

if [[ "$WARM_RESULT" = "reused" ]]; then
  remote_execution_mark_success "→ Cache volume '$NSC_NIX_CACHE_TAG' was already warm for scope '$WARM_SCOPE'."
else
  remote_execution_mark_success "→ Cache volume '$NSC_NIX_CACHE_TAG' was warmed for scope '$WARM_SCOPE'."
fi
