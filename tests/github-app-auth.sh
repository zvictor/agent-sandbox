#!/usr/bin/env bash
# Offline integration checks for the GitHub App launcher shims.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
AGENT_BIN_DIR="$ROOT/bin"
# shellcheck source=../bin/lib/github_app.sh
. "$ROOT/bin/lib/github_app.sh"
# shellcheck source=../bin/lib/container_runtime.sh
. "$ROOT/bin/lib/container_runtime.sh"

temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
PATH_GUARD_HOST_DIR="$temp/path-guard"
mkdir -p "$PATH_GUARD_HOST_DIR"

# A direct checkout can run on a host without the broker dependencies on PATH.
mkdir -p "$temp/empty" "$temp/tools/bin"
for tool in python3 openssl curl; do
  ln -s /bin/true "$temp/tools/bin/$tool"
done
(
  PATH="$temp/tools/bin"
  nix_cmd() { echo 'unexpected Nix build' >&2; return 1; }
  prepare_github_app_host_tools
  test "$GITHUB_APP_HOST_PATH" = "$temp/tools/bin"
)
(
  PATH="$temp/empty"
  AGENT_BIN_DIR="$ROOT/bin"
  RUNTIME_LEASE_DIR="$temp"
  nix_cmd() {
    test "$#" -eq 5 || return 1
    test "$1" = build || return 1
    test "$2" = --out-link || return 1
    test "$3" = "$RUNTIME_LEASE_DIR/github-app-host-tools" || return 1
    test "$4" = --print-out-paths || return 1
    test "$5" = "path:$AGENT_BIN_DIR/..#github-app-host-tools" || return 1
    printf '%s\n' "$temp/tools"
  }
  prepare_github_app_host_tools
  test "$GITHUB_APP_HOST_PATH" = "$temp/tools/bin:$temp/empty"
  for tool in python3 openssl curl; do
    PATH="$GITHUB_APP_HOST_PATH" command -v "$tool" >/dev/null
  done
)
(
  PATH="$temp/empty"
  AGENT_BIN_DIR="$ROOT/bin"
  RUNTIME_LEASE_DIR="$temp"
  nix_cmd() { return 1; }
  if prepare_github_app_host_tools; then
    exit 1
  fi
)
mkdir -p "$temp/incomplete-tools/bin"
ln -s /bin/true "$temp/incomplete-tools/bin/python3"
(
  PATH="$temp/empty"
  AGENT_BIN_DIR="$ROOT/bin"
  RUNTIME_LEASE_DIR="$temp"
  nix_cmd() { printf '%s\n' "$temp/incomplete-tools"; }
  if prepare_github_app_host_tools; then
    echo 'incomplete host tools unexpectedly accepted' >&2
    exit 1
  fi
)

GITHUB_APP_AUTH_MODE=app
GITHUB_APP_BROKER_DIR="$temp/github-app"
# Partial overrides must fail without attempting discovery or adding args.
for identity in name-only email-only; do
  (
    unset AGENT_GITHUB_APP_BOT_NAME AGENT_GITHUB_APP_BOT_EMAIL
    case "$identity" in
      name-only) AGENT_GITHUB_APP_BOT_NAME='example[bot]' ;;
      email-only) AGENT_GITHUB_APP_BOT_EMAIL='12345+example[bot]@users.noreply.github.com' ;;
    esac
    python3() { echo 'unexpected discovery' >&2; exit 1; }
    if prepare_github_app_identity /host/key.pem; then
      echo 'partial App identity unexpectedly accepted' >&2
      exit 1
    fi
    ARGS=()
    if append_github_app_container_args; then
      echo 'missing App identity unexpectedly added to container' >&2
      exit 1
    fi
    test "${#ARGS[@]}" -eq 0
  )
done
(
  unset AGENT_GITHUB_APP_BOT_NAME AGENT_GITHUB_APP_BOT_EMAIL
  GITHUB_APP_HOST_PATH="$PATH"
  AGENT_BIN_DIR="$ROOT/bin"
  AGENT_GITHUB_APP_ID=42
  AGENT_GITHUB_INSTALLATION_ID=123
  AGENT_GITHUB_APP_REPOSITORIES=example-repo
  python3() {
    test "$#" -eq 6 || return 1
    test "$1" = "$ROOT/bin/agent-github-app-broker" || return 1
    test "$2" = --identity || return 1
    test "$3" = 42 && test "$4" = 123 || return 1
    test "$5" = /host/key.pem && test "$6" = example-repo || return 1
    printf '%s\n' 'example[bot]' '98765+example[bot]@users.noreply.github.com'
  }
  prepare_github_app_identity /host/key.pem
  test "$AGENT_GITHUB_APP_BOT_NAME" = 'example[bot]'
  test "$AGENT_GITHUB_APP_BOT_EMAIL" = '98765+example[bot]@users.noreply.github.com'
  Z_SUFFIX=""
  ARGS=()
  append_github_app_container_args
  grep -Fxq 'GIT_CONFIG_VALUE_5=98765+example[bot]@users.noreply.github.com' <<< "$(printf '%s\n' "${ARGS[@]}")"
)
for discovery in failure malformed; do
  (
    unset AGENT_GITHUB_APP_BOT_NAME AGENT_GITHUB_APP_BOT_EMAIL
    GITHUB_APP_HOST_PATH="$PATH"
    AGENT_BIN_DIR="$ROOT/bin"
    AGENT_GITHUB_APP_ID=42
    AGENT_GITHUB_INSTALLATION_ID=123
    python3() {
      [ "$discovery" != failure ] || return 1
      printf 'incomplete-response\n'
    }
    if prepare_github_app_identity /host/key.pem; then
      echo 'failed identity discovery unexpectedly accepted' >&2
      exit 1
    fi
    test -z "${AGENT_GITHUB_APP_BOT_NAME:-}"
    test -z "${AGENT_GITHUB_APP_BOT_EMAIL:-}"
  )
done
AGENT_GITHUB_APP_BOT_NAME='example[bot]'
AGENT_GITHUB_APP_BOT_EMAIL='12345+example[bot]@users.noreply.github.com'
(
  python3() { echo 'unexpected discovery for explicit identity' >&2; exit 1; }
  prepare_github_app_identity /host/key.pem
)
Z_SUFFIX=""
ARGS=()

prepare_github_app_commands
test -x "$PATH_GUARD_HOST_DIR/github-app-token"
test -x "$PATH_GUARD_HOST_DIR/github-app-git-credential"
test -x "$PATH_GUARD_HOST_DIR/gh"
bash -n "$PATH_GUARD_HOST_DIR/github-app-token"
bash -n "$PATH_GUARD_HOST_DIR/github-app-git-credential"
bash -n "$PATH_GUARD_HOST_DIR/gh"

append_github_app_container_args
joined="$(printf '%s\n' "${ARGS[@]}")"
grep -Fxq 'GIT_CONFIG_COUNT=7' <<< "$joined"
grep -Fxq 'GIT_CONFIG_KEY_0=credential.helper' <<< "$joined"
grep -Fxq 'GIT_CONFIG_VALUE_0=' <<< "$joined"
grep -Fxq 'GIT_CONFIG_VALUE_1=!/run/agent-path-guard/github-app-git-credential' <<< "$joined"
grep -Fxq 'GIT_CONFIG_VALUE_2=git@github.com:' <<< "$joined"
grep -Fxq 'GIT_CONFIG_VALUE_3=ssh://git@github.com/' <<< "$joined"
grep -Fxq 'GIT_CONFIG_VALUE_4=example[bot]' <<< "$joined"
grep -Fxq 'GIT_CONFIG_VALUE_5=12345+example[bot]@users.noreply.github.com' <<< "$joined"
grep -Fxq 'GIT_CONFIG_KEY_6=credential.https://github.com.useHttpPath' <<< "$joined"
grep -Fxq 'GIT_CONFIG_VALUE_6=true' <<< "$joined"

for reserved in GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GH_TOKEN GH_HOST GH_CONFIG_DIR GITHUB_TOKEN; do
  runtime_env_key_is_reserved "$reserved"
done
! runtime_env_key_is_reserved "NORMAL_ENV"

SSH_AUTH_SOCK="$temp/fake.sock"
append_ssh_agent_args
# No forwarded personal SSH sockets, even when SSH_AUTH_SOCK is set.
! grep -q 'ssh-auth.sock' <<< "$(printf '%s\n' "${ARGS[@]}")"
prepare_ssh_runtime_dir
test -z "${SSH_RUNTIME_DIR:-}"

# The config reset must override any previously configured personal helper.
GIT_CONFIG_COUNT=2 \
GIT_CONFIG_KEY_0=credential.helper \
GIT_CONFIG_VALUE_0= \
GIT_CONFIG_KEY_1=credential.helper \
GIT_CONFIG_VALUE_1='!/run/agent-path-guard/github-app-git-credential' \
git config --get-all credential.helper | tail -n 1 | grep -Fxq '!/run/agent-path-guard/github-app-git-credential'

cat > "$temp/direnv.env" <<'EOF_ENV'
GH_TOKEN=personal-token
GITHUB_TOKEN=personal-github-token
GIT_CONFIG_COUNT=2
GIT_CONFIG_KEY_0=credential.helper
SSH_AUTH_SOCK=/host/onepassword.sock
AGENT_GITHUB_APP_PRIVATE_KEY_FILE=/host/secret.pem
SAFE_VAR=preserved
EOF_ENV
DEV_ENV_ENV_FILE="$temp/direnv.env"
ARGS=()
append_dev_env_args
joined="$(printf '%s\n' "${ARGS[@]}")"
grep -Fxq "SAFE_VAR=preserved" <<< "$joined"
for forbidden in 'GH_TOKEN=' 'GITHUB_TOKEN=' 'GIT_CONFIG_COUNT=' 'GIT_CONFIG_KEY_0=' 'SSH_AUTH_SOCK=' 'AGENT_GITHUB_APP_PRIVATE_KEY_FILE='; do
  ! grep -Fq -- "$forbidden" <<< "$joined"
done

# Run the generated helpers with fake tokens and a fake gh executable.
cat > "$PATH_GUARD_HOST_DIR/github-app-token" <<'EOF_TEST_TOKEN'
#!/bin/sh
set -eu
[ "${1:-}" != unavailable/repo ] || exit 1
printf 'installation-token:%s\n' "${1:-default}"
EOF_TEST_TOKEN
cat > "$temp/real-gh" <<'EOF_TEST_GH'
#!/bin/sh
printf 'token=%s\nrepo=%s\n' "${GH_TOKEN:-unset}" "${GH_REPO:-unset}"
printf 'arg=%s\n' "$@"
EOF_TEST_GH
chmod +x "$temp/real-gh"
sed -e "s|/bin/gh|$temp/real-gh|g" \
    -e "s|GH_CONFIG_DIR=/cache/agent-github-app/gh|GH_CONFIG_DIR=$temp/gh-config|" \
    "$ROOT/scripts/image/github-app-gh.sh" > "$PATH_GUARD_HOST_DIR/gh"
chmod +x "$PATH_GUARD_HOST_DIR/gh"

mkdir -p "$temp/checkout" "$temp/no-repo"
git init -q "$temp/checkout"
git -C "$temp/checkout" remote add origin git@github.com:personal/project.git
(
  cd "$temp/checkout"
  unset GH_REPO GH_TOKEN GITHUB_TOKEN
  output="$("$PATH_GUARD_HOST_DIR/gh" pr view)"
  grep -Fxq 'token=installation-token:personal/project' <<< "$output"
  for args in '-R org/project' '--repo=org/project' '-Rorg/project'; do
    read -r -a repo_args <<< "$args"
    output="$("$PATH_GUARD_HOST_DIR/gh" pr view "${repo_args[@]}")"
    grep -Fxq 'token=installation-token:org/project' <<< "$output"
    grep -Fxq 'repo=org/project' <<< "$output"
  done
  output="$(GH_REPO=org/project "$PATH_GUARD_HOST_DIR/gh" workflow list)"
  grep -Fxq 'token=installation-token:org/project' <<< "$output"
  for endpoint in repos/org/project/issues /repos/org/project/issues https://api.github.com/repos/org/project/issues; do
    output="$("$PATH_GUARD_HOST_DIR/gh" api "$endpoint")"
    grep -Fxq 'token=installation-token:org/project' <<< "$output"
  done
  output="$("$PATH_GUARD_HOST_DIR/gh" repo clone org/project)"
  grep -Fxq 'token=installation-token:org/project' <<< "$output"
  output="$("$PATH_GUARD_HOST_DIR/gh" pr view https://github.com/org/project/pull/2)"
  grep -Fxq 'token=installation-token:org/project' <<< "$output"
  output="$("$PATH_GUARD_HOST_DIR/gh" repo view org/project -R personal/project)"
  grep -Fxq 'token=installation-token:org/project' <<< "$output"
  output="$("$PATH_GUARD_HOST_DIR/gh" api 'repos/org/project?unused=value')"
  grep -Fxq 'token=installation-token:org/project' <<< "$output"
  output="$(GH_REPO=org/project "$PATH_GUARD_HOST_DIR/gh" api 'repos/{owner}/{repo}/issues')"
  grep -Fxq 'token=installation-token:org/project' <<< "$output"
  git remote add upstream https://github.com/org/project.git
  git config remote.upstream.gh-resolved base
  output="$("$PATH_GUARD_HOST_DIR/gh" pr view)"
  grep -Fxq 'token=installation-token:org/project' <<< "$output"
)
(
  cd "$temp/no-repo"
  unset GH_REPO GH_TOKEN GITHUB_TOKEN
  output="$("$PATH_GUARD_HOST_DIR/gh" api installation/repositories)"
  grep -Fxq 'token=installation-token:default' <<< "$output"
  output="$(GH_REPO=unavailable/repo "$PATH_GUARD_HOST_DIR/gh" --version)"
  grep -Fxq 'token=unset' <<< "$output"
  if output="$(GH_REPO=unavailable/repo "$PATH_GUARD_HOST_DIR/gh" pr view 2> "$temp/gh-error")"; then
    echo 'gh ran after failed token selection' >&2
    exit 1
  fi
  test -z "$output"
  grep -q 'authentication failed' "$temp/gh-error"
)

# Git must pass the repository path through its actual credential protocol.
for repository in personal/project org/project; do
  output="$(printf 'url=https://github.com/%s.git\n\n' "$repository" | \
    GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
    GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1="!$PATH_GUARD_HOST_DIR/github-app-git-credential" \
    GIT_CONFIG_KEY_2=credential.https://github.com.useHttpPath GIT_CONFIG_VALUE_2=true \
    git credential fill)"
  grep -Fxq "password=installation-token:$repository" <<< "$output"
done

# A persistent lease must replace its real broker when IDs or scopes change.
# Health checks do not mint tokens, so this uses a dummy key and no GitHub calls.
(
  . "$ROOT/bin/lib/runtime_lease.sh"
  PROJECT_ROOT="$temp/lifecycle-project"
  AGENT_WORKSPACE_PATH="$PROJECT_ROOT"
  RUNTIME_LEASE_DIR="$temp/lifecycle-lease"
  mkdir -p "$PROJECT_ROOT" "$RUNTIME_LEASE_DIR"
  AGENT_GITHUB_AUTH=app
  AGENT_GITHUB_APP_ID=42
  AGENT_GITHUB_INSTALLATION_ID=123
  AGENT_GITHUB_APP_PRIVATE_KEY_FILE="$temp/lifecycle-key.pem"
  printf 'unused offline test key\n' > "$AGENT_GITHUB_APP_PRIVATE_KEY_FILE"
  unset AGENT_GITHUB_APP_REPOSITORIES
  prepare_github_app_host_tools() { GITHUB_APP_HOST_PATH="$PATH"; }
  trap 'stop_runtime_lease_github_app_broker "$RUNTIME_LEASE_DIR"' EXIT
  prepare_github_app_auth
  first_pid="$(cat "$GITHUB_APP_BROKER_PID_FILE")"
  prepare_github_app_auth
  test "$(cat "$GITHUB_APP_BROKER_PID_FILE")" = "$first_pid"
  AGENT_GITHUB_INSTALLATION_ID=123,456
  prepare_github_app_auth
  second_pid="$(cat "$GITHUB_APP_BROKER_PID_FILE")"
  test "$second_pid" != "$first_pid"
  ! kill -0 "$first_pid" 2>/dev/null
  AGENT_GITHUB_APP_REPOSITORIES=personal/one,org/two
  prepare_github_app_auth
  test "$(cat "$GITHUB_APP_BROKER_PID_FILE")" != "$second_pid"
  ! kill -0 "$second_pid" 2>/dev/null
)

echo "GitHub App launcher checks passed"
