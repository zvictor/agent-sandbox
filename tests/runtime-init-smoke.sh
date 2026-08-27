#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
RUNTIME_RECEIPTS_DIR="/run/agent-runtime-receipts"
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

  require_command nix
  env -u NIX_CONFIG nix --extra-experimental-features "$nix_features" build \
    "$REPO_ROOT#rootfs" --out-link "$root_link"
  [ -d "$root_link" ] || fail "rootfs build did not produce a directory"
  printf '%s\n' "$root_link"
}

rootfs_from_runtime_receipt() {
  local lease_manifest="$RUNTIME_RECEIPTS_DIR/lease.json"
  local rootfs_receipt="$RUNTIME_RECEIPTS_DIR/runtime-rootfs.json"
  local rootfs=""

  require_command jq
  [ -r "$lease_manifest" ] || fail "runtime lease manifest is unreadable: $lease_manifest"
  [ -r "$rootfs_receipt" ] || fail "runtime rootfs receipt is unreadable: $rootfs_receipt"

  rootfs="$(
    jq -er \
      --slurpfile lease "$lease_manifest" \
      'select(
        ($lease | length) == 1 and
        $lease[0].schema_version == 1 and
        $lease[0].owner == "agent-sandbox" and
        $lease[0].retention == "until-sandbox-teardown" and
        .schema_version == 1 and
        .lease_id == $lease[0].lease_id and
        .kind == "runtime-artifact" and
        .artifact == "rootfs" and
        (.output_paths | type) == "array" and
        (.output_paths | length) == 1 and
        (.output_paths[0] | type) == "string" and
        (.closure | type) == "array" and
        (.output_paths[0] as $output_path | .closure | any(.path == $output_path))
      ) | .output_paths[0]' \
      "$rootfs_receipt" 2>/dev/null
  )" || fail "runtime rootfs receipt failed validation"

  [ -d "$rootfs" ] || fail "retained runtime rootfs is unavailable: $rootfs"
  printf '%s\n' "$rootfs"
}

resolve_rootfs() {
  if [ -e "$RUNTIME_RECEIPTS_DIR/lease.json" ] || [ -e "$RUNTIME_RECEIPTS_DIR/runtime-rootfs.json" ]; then
    rootfs_from_runtime_receipt
  else
    build_rootfs
  fi
}

main() {
  local rootfs=""

  require_command podman
  TMP_DIR="$(mktemp -d)"
  CONTAINER_NAME="agent-pid1-reaper-$RANDOM-$$"
  trap cleanup EXIT

  rootfs="$(resolve_rootfs)"
  podman run --rm \
    --name "$CONTAINER_NAME" \
    --init \
    --network=none \
    --security-opt=label=disable \
    -v /nix/store:/nix/store:ro \
    -v "$REPO_ROOT/tests/pid1-reaper-probe.sh:/run/agent-pid1-reaper-probe:ro" \
    --entrypoint /bin/bash \
    --rootfs "$rootfs:O" \
    /run/agent-pid1-reaper-probe
  CONTAINER_NAME=""
}

main "$@"
