#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "[fail] $*" >&2
  exit 1
}

info() {
  echo "[info] $*"
}

TMP_DIR=""

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

require_kvm_device() {
  [ -c /dev/kvm ] || fail "/dev/kvm is not present"
  [ -r /dev/kvm ] || fail "/dev/kvm is not readable"
  [ -w /dev/kvm ] || fail "/dev/kvm is not writable"
}

resolve_qemu_cmd() {
  if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    QEMU_CMD=(qemu-system-x86_64)
    return 0
  fi

  if command -v need >/dev/null 2>&1; then
    info "injecting qemu via need"
    need inject qemu >/dev/null
    if command -v qemu-system-x86_64 >/dev/null 2>&1; then
      QEMU_CMD=(qemu-system-x86_64)
      return 0
    fi
  fi

  if command -v nix >/dev/null 2>&1; then
    info "using qemu from nix shell"
    QEMU_CMD=(nix shell nixpkgs#qemu --command qemu-system-x86_64)
    return 0
  fi

  fail "qemu-system-x86_64 is unavailable and no nix fallback exists"
}

print_qemu_version() {
  "${QEMU_CMD[@]}" --version | head -n 1
}

run_microvm_smoke_test() {
  local status
  TMP_DIR="$(mktemp -d)"

  set +e
  timeout "${MICROVM_TEST_TIMEOUT:-5s}" \
    "${QEMU_CMD[@]}" \
    -accel kvm \
    -M microvm \
    -m "${MICROVM_TEST_MEMORY_MB:-256}" \
    -nodefaults \
    -no-user-config \
    -nographic \
    -display none \
    -monitor none \
    -serial none \
    -S \
    >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr"
  status=$?
  set -e

  case "$status" in
    124)
      if grep -Eiq 'failed to initialize kvm|could not access kvm kernel module|tcg|invalid accelerator|not found' "$TMP_DIR/stderr"; then
        sed -n '1,120p' "$TMP_DIR/stderr" >&2
        fail "qemu reported a KVM or accelerator failure"
      fi
      info "microvm launch stayed alive until timeout; KVM-backed startup worked"
      ;;
    *)
      sed -n '1,120p' "$TMP_DIR/stderr" >&2 || true
      fail "qemu exited unexpectedly with status $status"
      ;;
  esac
}

main() {
  trap cleanup EXIT
  require_kvm_device
  resolve_qemu_cmd
  print_qemu_version
  run_microvm_smoke_test
}

main "$@"
