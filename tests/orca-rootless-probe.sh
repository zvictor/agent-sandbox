#!/usr/bin/env bash
set -euo pipefail

# Exercise the production nested-Podman setup from a user-namespaced terminal.
repo_root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
export AGENT_SANDBOX_PROFILE=rootless-linux
export AGENT_ROOTLESS_LINUX_PROBE_ONLY=1
exec "$repo_root/scripts/codex"
