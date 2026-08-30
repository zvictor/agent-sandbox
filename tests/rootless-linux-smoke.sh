#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

AGENT_SANDBOX_PROFILE=rootless-linux \
AGENT_ALLOW_SUDO=0 \
AGENT_ROOTLESS_LINUX_PROBE_ONLY=1 \
  "$REPO_ROOT/scripts/codex"
