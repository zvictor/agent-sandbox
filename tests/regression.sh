#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

fail() {
  echo "[fail] $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  case "$haystack" in
    *"$needle"*) ;;
    *)
      fail "expected output to contain: $needle"
      ;;
  esac
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"

  case "$haystack" in
    *"$needle"*)
      fail "expected output not to contain: $needle"
      ;;
    *)
      ;;
  esac
}

test_opencode_wrapper_default() (
  set -euo pipefail

  local tmp_dir output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  mkdir -p "$tmp_dir/bin" "$tmp_dir/scripts"
  cp "$REPO_ROOT/scripts/opencode" "$tmp_dir/scripts/opencode"
  chmod +x "$tmp_dir/scripts/opencode"

  cat > "$tmp_dir/bin/agent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'permission=%s\n' "${OPENCODE_PERMISSION:-}"
printf 'argv=%s\n' "$*"
EOF
  chmod +x "$tmp_dir/bin/agent"

  output="$(env -i PATH="/usr/bin:/bin" "$tmp_dir/scripts/opencode" alpha beta)"
  assert_contains "$output" "permission=allow"
  assert_contains "$output" "argv=opencode alpha beta"

  output="$(env -i PATH="/usr/bin:/bin" OPENCODE_PERMISSION=ask "$tmp_dir/scripts/opencode" alpha)"
  assert_contains "$output" "permission=ask"
  assert_contains "$output" "argv=opencode alpha"
)

test_runtime_resolution_parity() (
  set -euo pipefail

  local bad_runtime doctor_output run_output status=0
  bad_runtime="definitely-not-a-runtime"

  doctor_output="$(cd "$REPO_ROOT" && AGENT_RUNTIME="$bad_runtime" AGENT_TOOLS=all ./scripts/agent doctor 2>&1)"
  assert_contains "$doctor_output" "requested runtime '$bad_runtime' is not available"

  set +e
  run_output="$(cd "$REPO_ROOT" && AGENT_RUNTIME="$bad_runtime" AGENT_TOOLS=all ./scripts/agent codex 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "expected agent run with an unavailable runtime to fail"
  assert_contains "$run_output" "[agent] requested runtime '$bad_runtime' is not available"
)

test_git_wrapper_policy() (
  set -euo pipefail

  local image_file
  image_file="$(cat "$REPO_ROOT/nix/image.nix")"

  assert_contains "$image_file" 'SAFE_COMMANDS="clone|status|diff|log|show|ls-files|rev-parse|describe|ls-tree|cat-file|blame|grep|reflog|for-each-ref|rev-list|shortlog|symbolic-ref|name-rev|merge-base"'
  assert_not_contains "$image_file" 'clone|fetch'
  assert_not_contains "$image_file" '|branch|'
  assert_not_contains "$image_file" '|config|'
  assert_not_contains "$image_file" '|remote|'
  assert_not_contains "$image_file" '|tag|'
)

run_test() {
  local name="$1"
  shift

  echo "[test] $name"
  "$@"
}

main() {
  run_test "opencode wrapper default" test_opencode_wrapper_default
  run_test "runtime resolution parity" test_runtime_resolution_parity
  run_test "git wrapper policy" test_git_wrapper_policy
}

main "$@"
