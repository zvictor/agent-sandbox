#!/usr/bin/env bash
# Offline integration checks for the GitHub App launcher shims.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
# shellcheck source=../bin/lib/github_app.sh
. "$ROOT/bin/lib/github_app.sh"
# shellcheck source=../bin/lib/container_runtime.sh
. "$ROOT/bin/lib/container_runtime.sh"

temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
PATH_GUARD_HOST_DIR="$temp/path-guard"
mkdir -p "$PATH_GUARD_HOST_DIR"

GITHUB_APP_AUTH_MODE=app
GITHUB_APP_BROKER_DIR="$temp/github-app"
AGENT_GITHUB_APP_BOT_NAME='example[bot]'
AGENT_GITHUB_APP_BOT_EMAIL='12345+example[bot]@users.noreply.github.com'
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
grep -Fxq 'GIT_CONFIG_COUNT=6' <<< "$joined"
grep -Fxq 'GIT_CONFIG_KEY_0=credential.helper' <<< "$joined"
grep -Fxq 'GIT_CONFIG_VALUE_0=' <<< "$joined"
grep -Fxq 'GIT_CONFIG_VALUE_1=!/run/agent-path-guard/github-app-git-credential' <<< "$joined"
grep -Fxq 'GIT_CONFIG_VALUE_2=git@github.com:' <<< "$joined"
grep -Fxq 'GIT_CONFIG_VALUE_3=ssh://git@github.com/' <<< "$joined"
grep -Fxq 'GIT_CONFIG_VALUE_4=example[bot]' <<< "$joined"
grep -Fxq 'GIT_CONFIG_VALUE_5=12345+example[bot]@users.noreply.github.com' <<< "$joined"

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

echo "GitHub App launcher checks passed"
