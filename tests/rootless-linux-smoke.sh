#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
mount_fixture="$(mktemp -d)"
trap 'rmdir "$mount_fixture"' EXIT

AGENT_SANDBOX_PROFILE=rootless-linux \
AGENT_ALLOW_SUDO=0 \
AGENT_EXTRA_MOUNTS="$mount_fixture:/agent-extra-mount-probe:ro" \
AGENT_ROOTLESS_LINUX_PROBE_ONLY=1 \
  "$REPO_ROOT/scripts/codex"
