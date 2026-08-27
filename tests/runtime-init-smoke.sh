#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP_DIR=""
CONTAINER_NAME=""

fail() {
  echo "[fail] $*" >&2
  exit 1
}

cleanup() {
  if [ -n "$CONTAINER_NAME" ]; then
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

build_rootfs() {
  local root_link="$TMP_DIR/rootfs"
  local nix_features="${AGENT_NIX_EXPERIMENTAL_FEATURES:-nix-command flakes}"

  env -u NIX_CONFIG nix --extra-experimental-features "$nix_features" build \
    "$REPO_ROOT#rootfs" --out-link "$root_link"
  [ -d "$root_link" ] || fail "rootfs build did not produce a directory"
  printf '%s\n' "$root_link"
}

main() {
  local rootfs=""

  require_command nix
  require_command podman
  TMP_DIR="$(mktemp -d)"
  CONTAINER_NAME="agent-pid1-reaper-$RANDOM-$$"
  trap cleanup EXIT

  rootfs="$(build_rootfs)"
  podman run --rm \
    --name "$CONTAINER_NAME" \
    --init \
    --network=none \
    --security-opt=label=disable \
    -v "$REPO_ROOT/tests/pid1-reaper-probe.sh:/run/agent-pid1-reaper-probe:ro" \
    --entrypoint /bin/bash \
    --rootfs "$rootfs:O" \
    /run/agent-pid1-reaper-probe
  CONTAINER_NAME=""
}

main "$@"
