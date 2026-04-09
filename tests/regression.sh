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

workspace_mount_args_for() (
  set -euo pipefail

  local workspace_path="$1"
  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  WORKSPACE_PATH="$workspace_path"
  Z_SUFFIX=""
  ARGS=()
  append_workspace_mount_args

  printf '%s\n' "${ARGS[@]}"
)

passthrough_env_args_for() (
  set -euo pipefail

  split_csv_or_lines() {
    local value="$1"
    printf '%s\n' "$value" | tr ',' '\n' | sed '/^[[:space:]]*$/d'
  }

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  ARGS=()
  append_passthrough_env_args

  printf '%s\n' "${ARGS[@]}"
)

ssh_agent_args_for() (
  set -euo pipefail

  local socket_path="$1"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  resolve_ssh_auth_socket() {
    printf '%s\n' "$socket_path"
  }

  Z_SUFFIX=""
  ARGS=()
  append_ssh_agent_args

  printf '%s\n' "${ARGS[@]}"
)

prepare_ssh_runtime_for() (
  set -euo pipefail

  local host_home="$1"
  local tool_cache_dir="$2"
  local resolved_sock="${3:-}"
  local tool_name="${4:-}"
  local workspace_path="${5:-}"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  HOST_HOME="$host_home"
  TOOL_CACHE_DIR="$tool_cache_dir"
  TOOL="$tool_name"
  WORKSPACE_PATH="$workspace_path"

  resolve_ssh_auth_socket() {
    printf '%s\n' "$resolved_sock"
  }

  prepare_ssh_runtime_dir

  if [ -n "${SSH_RUNTIME_DIR:-}" ]; then
    printf '%s\n' "$SSH_RUNTIME_DIR"
  fi
)

ssh_runtime_mount_args_for() (
  set -euo pipefail

  local runtime_dir="$1"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  prepare_ssh_runtime_dir() {
    SSH_RUNTIME_DIR="$runtime_dir"
  }

  Z_SUFFIX=""
  ARGS=()
  append_ssh_runtime_mount_args

  printf '%s\n' "${ARGS[@]}"
)

codex_ssh_alias_args_for() (
  set -euo pipefail

  local runtime_dir="$1"
  local workspace_path="$2"
  local resolved_sock="$3"

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  TOOL="codex"
  WORKSPACE_PATH="$workspace_path"
  SSH_RUNTIME_DIR="$runtime_dir"

  resolve_ssh_auth_socket() {
    printf '%s\n' "$resolved_sock"
  }

  Z_SUFFIX=""
  ARGS=()
  append_codex_ssh_alias_args

  printf '%s\n' "${ARGS[@]}"
)

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

test_host_home_fallbacks_present() (
  set -euo pipefail

  local environment_file
  environment_file="$(cat "$REPO_ROOT/bin/lib/environment.sh")"

  assert_contains "$environment_file" 'if [ -z "$HOST_HOME" ] && [ -n "${USER:-}" ] && [ -d "/home/$USER" ]; then'
  assert_contains "$environment_file" 'if [ -z "$HOST_HOME" ] && [ -n "${LOGNAME:-}" ] && [ -d "/home/$LOGNAME" ]; then'
  assert_contains "$environment_file" 'done < <(find /home -mindepth 1 -maxdepth 1 -type d -user "$(id -u)" 2>/dev/null)'
  assert_contains "$environment_file" 'done < <(find /Users -mindepth 1 -maxdepth 1 -type d -user "$(id -u)" 2>/dev/null)'
  assert_contains "$environment_file" 'project_root_tail="${PROJECT_ROOT#/home/}"'
  assert_contains "$environment_file" 'project_root_tail="${PROJECT_ROOT#/Users/}"'
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

test_device_passthrough_support() (
  set -euo pipefail

  local runtime_file config_file readme_file
  runtime_file="$(cat "$REPO_ROOT/bin/lib/container_runtime.sh")"
  config_file="$(cat "$REPO_ROOT/docs/CONFIG.md")"
  readme_file="$(cat "$REPO_ROOT/README.md")"

  assert_contains "$runtime_file" 'append_split_arg_values --device "$device_specs"'
  assert_contains "$runtime_file" 'AGENT_ALLOW_KVM'
  assert_contains "$config_file" '`AGENT_EXTRA_DEVICES`'
  assert_contains "$config_file" '`AGENT_ALLOW_KVM=1`'
  assert_contains "$readme_file" '`AGENT_EXTRA_DEVICES`'
)

test_kvm_smoke_script() (
  set -euo pipefail

  local script_file
  script_file="$(cat "$REPO_ROOT/tests/kvm-smoke.sh")"

  assert_contains "$script_file" 'need inject qemu'
  assert_contains "$script_file" '-accel kvm'
  assert_contains "$script_file" '-M microvm'
  assert_contains "$script_file" 'MICROVM_TEST_TIMEOUT'
)

test_bun_latest_lookup_uses_tool_cache() (
  set -euo pipefail

  local image_file
  image_file="$(cat "$REPO_ROOT/nix/image.nix")"

  assert_contains "$image_file" 'latest_version="$((cd "$CACHE_DIR" && ${pkgs.bun}/bin/bun info ${pkg} version) 2>/dev/null | head -n1 || true)"'
)

test_codex_bubblewrap_compat_path() (
  set -euo pipefail

  local image_file readme_file
  image_file="$(cat "$REPO_ROOT/nix/image.nix")"
  readme_file="$(cat "$REPO_ROOT/README.md")"

  assert_contains "$image_file" 'bubblewrapCompat = pkgs.runCommand "bubblewrap-compat"'
  assert_contains "$image_file" 'ln -s ${pkgs.bubblewrap}/bin/bwrap "$out/usr/bin/bwrap"'
  assert_contains "$readme_file" '`agent codex` can now use Codex'\''s native Bubblewrap sandbox inside the outer container because the image provides `/usr/bin/bwrap`.'
)

test_workspace_mounts_for_regular_repo_workspace_override() (
  set -euo pipefail

  local tmp_dir repo workspace git_top output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  repo="$tmp_dir/repo"
  workspace="$repo/subdir"
  mkdir -p "$workspace"
  git -C "$repo" init -q
  printf 'hello\n' > "$repo/file.txt"
  printf 'nested\n' > "$workspace/nested.txt"
  git -C "$repo" add file.txt subdir/nested.txt
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -qm init

  git_top="$(git -C "$workspace" rev-parse --show-toplevel)"
  output="$(workspace_mount_args_for "$workspace")"

  assert_contains "$output" "$git_top:$git_top:rw"
)

test_workspace_mounts_for_linked_worktree_workspace_override() (
  set -euo pipefail

  local tmp_dir repo workspace worktree git_top git_common_dir output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  repo="$tmp_dir/repo"
  worktree="$tmp_dir/worktree"
  mkdir -p "$repo/subdir"
  git -C "$repo" init -q
  printf 'hello\n' > "$repo/file.txt"
  printf 'nested\n' > "$repo/subdir/nested.txt"
  git -C "$repo" add file.txt subdir/nested.txt
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -qm init
  git -C "$repo" worktree add -q "$worktree" -b feature

  workspace="$worktree/subdir"
  git_top="$(git -C "$workspace" rev-parse --show-toplevel)"
  git_common_dir="$(
    cd "$workspace" &&
    cd "$(git -C "$workspace" rev-parse --git-common-dir)" &&
    pwd -P
  )"
  output="$(workspace_mount_args_for "$workspace")"

  [ "$git_common_dir" != "$git_top" ] || fail "expected linked worktree common dir to differ from worktree top-level"
  assert_contains "$output" "$git_top:$git_top:rw"
  assert_contains "$output" "$git_common_dir:$git_common_dir:rw"
)

test_config_selectors_are_not_passthrough_env() (
  set -euo pipefail

  local output
  output="$(
    env \
      CODEX_CONFIG=project \
      CODEX_AUTH=work \
      OPENCODE_CONFIG=fresh \
      CLAUDE_AUTH=other \
      CODEX_FOO=bar \
      GIT_ALLOW=1 \
      REPO_ROOT="$REPO_ROOT" \
      bash -lc '
        split_csv_or_lines() {
          local value="$1"
          printf "%s\n" "$value" | tr "," "\n" | sed "/^[[:space:]]*$/d"
        }
        source "$REPO_ROOT/bin/lib/container_runtime.sh"
        ARGS=()
        append_passthrough_env_args
        printf "%s\n" "${ARGS[@]}"
      '
  )"

  assert_not_contains "$output" "CODEX_CONFIG=project"
  assert_not_contains "$output" "CODEX_AUTH=work"
  assert_not_contains "$output" "OPENCODE_CONFIG=fresh"
  assert_not_contains "$output" "CLAUDE_AUTH=other"
  assert_not_contains "$output" "SSH_AUTH_SOCK="
  assert_contains "$output" "CODEX_FOO=bar"
  assert_contains "$output" "GIT_ALLOW=1"
)

test_ssh_agent_mount_support() (
  set -euo pipefail

  local socket_path output
  socket_path="/tmp/test-ssh-agent.sock"

  output="$(ssh_agent_args_for "$socket_path")"

  assert_contains "$output" "$socket_path:/run/host-services/ssh-auth.sock:rw"
  assert_contains "$output" "SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock"
)

test_ssh_runtime_generation() (
  set -euo pipefail

  local tmp_dir host_home ssh_dir runtime_dir wrapper_config codex_wrapper_config host_config include_config known_hosts_file mount_args codex_alias_args workspace codex_ssh_alias
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  host_home="$tmp_dir/host-home"
  ssh_dir="$host_home/.ssh"
  workspace="$tmp_dir/workspace"
  codex_ssh_alias="$workspace/.agent-sandbox-codex-ssh"
  mkdir -p "$ssh_dir/config.d" "$tmp_dir/tool-cache" "$workspace/.codex"

  cat > "$ssh_dir/config" <<EOF
Host *
        IdentityAgent ~/.1password/agent.sock
        ServerAliveInterval 60

Host trunk.koker.net
    ProxyCommand cloudflared access ssh --hostname %h
    User git

Include $host_home/.ssh/config.d/*.conf
EOF

  cat > "$ssh_dir/config.d/work.conf" <<'EOF'
Host github.com
    User git
EOF

  printf 'trunk.koker.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey\n' > "$ssh_dir/known_hosts"
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n' > "$ssh_dir/id_ed25519"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPublicKey user@example\n' > "$ssh_dir/id_ed25519.pub"

  runtime_dir="$(prepare_ssh_runtime_for "$host_home" "$tmp_dir/tool-cache" "/tmp/host-ssh-agent.sock" "codex" "$workspace")"
  [ -n "$runtime_dir" ] || fail "expected ssh runtime dir to be created"

  wrapper_config="$(cat "$runtime_dir/config")"
  codex_wrapper_config="$(cat "$runtime_dir/config.codex")"
  host_config="$(cat "$runtime_dir/config.host")"
  include_config="$(cat "$runtime_dir/config.d/work.conf")"
  known_hosts_file="$(cat "$runtime_dir/known_hosts")"
  mount_args="$(ssh_runtime_mount_args_for "$runtime_dir")"
  codex_alias_args="$(codex_ssh_alias_args_for "$runtime_dir" "$workspace" "/tmp/host-ssh-agent.sock")"

  assert_contains "$wrapper_config" "IdentityAgent /run/host-services/ssh-auth.sock"
  assert_contains "$wrapper_config" "UserKnownHostsFile /cache/.ssh/known_hosts /cache/.ssh/known_hosts2"
  assert_contains "$wrapper_config" "Include /cache/.ssh/config.host"
  assert_contains "$codex_wrapper_config" "IdentityAgent $codex_ssh_alias/agent.sock"
  assert_contains "$codex_wrapper_config" "UserKnownHostsFile $codex_ssh_alias/known_hosts $codex_ssh_alias/known_hosts2"
  assert_contains "$codex_wrapper_config" "Include $codex_ssh_alias/config.host"
  assert_contains "$host_config" "IdentityAgent ~/.1password/agent.sock"
  assert_contains "$host_config" "ProxyCommand cloudflared access ssh --hostname %h"
  assert_contains "$host_config" "Include /cache/.ssh/config.d/*.conf"
  assert_contains "$include_config" "Host github.com"
  assert_contains "$known_hosts_file" "trunk.koker.net ssh-ed25519"
  [ ! -e "$runtime_dir/id_ed25519" ] || fail "expected private key to be excluded from ssh runtime"
  [ -f "$runtime_dir/id_ed25519.pub" ] || fail "expected public key to be copied into ssh runtime"
  assert_contains "$mount_args" "$runtime_dir:/cache/.ssh:ro"
  assert_contains "$codex_alias_args" "$runtime_dir:$codex_ssh_alias:ro"
  assert_contains "$codex_alias_args" "/tmp/host-ssh-agent.sock:$codex_ssh_alias/agent.sock:rw"
  assert_contains "$codex_alias_args" "SSH_AUTH_SOCK=$codex_ssh_alias/agent.sock"
  assert_contains "$codex_alias_args" "GIT_SSH_COMMAND=ssh -F '$codex_ssh_alias/config.codex'"
)

codex_mount_args_for() (
  set -euo pipefail

  local workspace_path="$1"
  local config_root="$2"

  split_csv_or_lines() {
    local value="$1"
    printf '%s
' "$value" | tr ',' '
' | sed '/^[[:space:]]*$/d'
  }

  source "$REPO_ROOT/bin/lib/container_runtime.sh"

  WORKSPACE_PATH="$workspace_path"
  CODEX_CONFIG_MODE=host
  CODEX_HOST_CONFIG="$config_root"
  CODEX_AUTH_BASE=""
  Z_SUFFIX=""
  ARGS=()
  mount_standard_engine codex

  printf '%s
' "${ARGS[@]}"
)

test_codex_workspace_config_alias_mount() (
  set -euo pipefail

  local tmp_dir workspace config_root output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  config_root="$tmp_dir/codex-home"
  mkdir -p "$workspace" "$config_root"

  output="$(codex_mount_args_for "$workspace" "$config_root")"

  assert_contains "$output" "$config_root:/cache/.codex:rw"
  assert_contains "$output" "$config_root:$workspace/.codex:rw"
)


test_codex_workspace_config_alias_mount_skips_duplicate_path() (
  set -euo pipefail

  local tmp_dir workspace output
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  workspace="$tmp_dir/workspace"
  mkdir -p "$workspace/.codex"

  output="$(codex_mount_args_for "$workspace" "$workspace/.codex")"

  assert_contains "$output" "$workspace/.codex:/cache/.codex:rw"
  assert_not_contains "$output" "$workspace/.codex:$workspace/.codex:rw"
)

test_image_includes_openssh() (
  set -euo pipefail

  local image_file
  image_file="$(cat "$REPO_ROOT/nix/image.nix")"

  assert_contains "$image_file" "pkgs.openssh"
  assert_contains "$image_file" '"$out/run/host-services"'
)

test_need_defaults_to_unstable_nixpkgs() (
  set -euo pipefail

  local need_file image_file compat_file
  need_file="$(cat "$REPO_ROOT/scripts/image/need.sh")"
  image_file="$(cat "$REPO_ROOT/nix/image.nix")"
  compat_file="$(cat "$REPO_ROOT/scripts/image/agent-compat.sh")"

  assert_contains "$need_file" 'DEFAULT_NIXPKGS_FLAKE_REF="github:NixOS/nixpkgs/nixos-unstable"'
  assert_contains "$need_file" 'resolved_installable="${DEFAULT_NIXPKGS_FLAKE_REF}#$best_attr"'
  assert_contains "$compat_file" 'default_nixpkgs_flake_ref="github:NixOS/nixpkgs/nixos-unstable"'
  assert_contains "$image_file" '"NIX_PATH=nixpkgs=${unstablePkgs.path}"'
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
  run_test "host home fallbacks present" test_host_home_fallbacks_present
  run_test "git wrapper policy" test_git_wrapper_policy
  run_test "device passthrough support" test_device_passthrough_support
  run_test "kvm smoke script" test_kvm_smoke_script
  run_test "bun latest lookup uses tool cache" test_bun_latest_lookup_uses_tool_cache
  run_test "codex bubblewrap compat path" test_codex_bubblewrap_compat_path
  run_test "workspace mounts for regular repo override" test_workspace_mounts_for_regular_repo_workspace_override
  run_test "workspace mounts for linked worktree override" test_workspace_mounts_for_linked_worktree_workspace_override
  run_test "config selectors are not passthrough env" test_config_selectors_are_not_passthrough_env
  run_test "ssh agent mount support" test_ssh_agent_mount_support
  run_test "ssh runtime generation" test_ssh_runtime_generation
  run_test "codex workspace config alias mount" test_codex_workspace_config_alias_mount
  run_test "codex workspace config alias mount skips duplicate path" test_codex_workspace_config_alias_mount_skips_duplicate_path
  run_test "image includes openssh" test_image_includes_openssh
  run_test "need defaults to unstable nixpkgs" test_need_defaults_to_unstable_nixpkgs

  if [ "${AGENT_RUN_KVM_TESTS:-0}" = "1" ]; then
    run_test "microvm smoke" "$REPO_ROOT/tests/kvm-smoke.sh"
  fi
}

main "$@"
