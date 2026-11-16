# Opt-in, host-only GitHub App authentication for unattended agents.
GITHUB_APP_AUTH_MODE="none"
GITHUB_APP_BROKER_DIR=""
GITHUB_APP_BROKER_SOCKET=""
GITHUB_APP_BROKER_PID_FILE=""
GITHUB_APP_HOST_PATH=""

prepare_github_app_host_tools() {
  local tools_path="" tool=""
  GITHUB_APP_HOST_PATH="$PATH"
  if command -v python3 >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    return 0
  fi
  echo "[agent] preparing GitHub App host dependencies with Nix..." >&2
  tools_path="$(nix_cmd build --out-link "$RUNTIME_LEASE_DIR/github-app-host-tools" --print-out-paths "path:$AGENT_BIN_DIR/..#github-app-host-tools")" || {
    echo "[agent] failed to build GitHub App host dependencies" >&2
    return 1
  }
  GITHUB_APP_HOST_PATH="$tools_path/bin:$PATH"
  for tool in python3 openssl curl; do
    if ! PATH="$GITHUB_APP_HOST_PATH" command -v "$tool" >/dev/null 2>&1; then
      echo "[agent] GitHub App host dependency missing after Nix build: $tool" >&2
      return 1
    fi
  done
}

github_app_broker_running() {
  local pid="" cmd=""
  [ -n "$GITHUB_APP_BROKER_PID_FILE" ] && [ -f "$GITHUB_APP_BROKER_PID_FILE" ] || return 1
  pid="$(cat "$GITHUB_APP_BROKER_PID_FILE" 2>/dev/null || true)"
  case "$pid" in ""|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  else
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  fi
  case "$cmd" in
    *agent-github-app-broker*"$GITHUB_APP_BROKER_SOCKET"*) return 0 ;;
  esac
  return 1
}

validate_github_app_identity() {
  if [ -z "${AGENT_GITHUB_APP_BOT_NAME:-}" ] || [ -z "${AGENT_GITHUB_APP_BOT_EMAIL:-}" ]; then
    echo "[agent] GitHub App commit identity has not been resolved" >&2
    return 1
  fi
}

prepare_github_app_identity() {
  local identity=""
  local -a fields=()

  if [ -n "${AGENT_GITHUB_APP_BOT_NAME:-}" ] || [ -n "${AGENT_GITHUB_APP_BOT_EMAIL:-}" ]; then
    if ! validate_github_app_identity; then
      echo "[agent] set both AGENT_GITHUB_APP_BOT_NAME and AGENT_GITHUB_APP_BOT_EMAIL, or leave both unset for automatic discovery" >&2
      return 1
    fi
    return 0
  fi

  identity="$(PATH="$GITHUB_APP_HOST_PATH" python3 "$AGENT_BIN_DIR/agent-github-app-broker" \
    --identity "$AGENT_GITHUB_APP_ID" "$AGENT_GITHUB_INSTALLATION_ID" "$1" "${AGENT_GITHUB_APP_REPOSITORIES:-}")" || {
    echo "[agent] failed to discover GitHub App commit identity; check GitHub access or set both bot identity settings explicitly" >&2
    return 1
  }
  mapfile -t fields <<< "$identity"
  if [ "${#fields[@]}" -ne 2 ] || [ -z "${fields[0]:-}" ] || [ -z "${fields[1]:-}" ]; then
    echo "[agent] invalid GitHub App commit identity response" >&2
    return 1
  fi
  AGENT_GITHUB_APP_BOT_NAME="${fields[0]}"
  AGENT_GITHUB_APP_BOT_EMAIL="${fields[1]}"
}

prepare_github_app_auth() {
  local private_key="" workspace="" attempt=0 pid="" fingerprint="" expected_health=""
  GITHUB_APP_AUTH_MODE="${AGENT_GITHUB_AUTH:-none}"
  case "$GITHUB_APP_AUTH_MODE" in
    none|0) return 0 ;;
    app) ;;
    *) echo "[agent] AGENT_GITHUB_AUTH must be 'none' or 'app'" >&2; return 1 ;;
  esac

  prepare_github_app_host_tools || return 1
  case "${AGENT_GITHUB_APP_ID:-}" in
    ""|*[!0-9]*) echo "[agent] AGENT_GITHUB_APP_ID must be numeric" >&2; return 1 ;;
  esac
  case "${AGENT_GITHUB_INSTALLATION_ID:-}" in
    ""|*[!0-9,]*|,*|*,|*,,*) echo "[agent] AGENT_GITHUB_INSTALLATION_ID must contain comma-separated numeric IDs" >&2; return 1 ;;
  esac
  [ -n "${AGENT_GITHUB_APP_PRIVATE_KEY_FILE:-}" ] && [ -f "$AGENT_GITHUB_APP_PRIVATE_KEY_FILE" ] \
    && [ -r "$AGENT_GITHUB_APP_PRIVATE_KEY_FILE" ] || {
    echo "[agent] AGENT_GITHUB_APP_PRIVATE_KEY_FILE must name a readable host-side key file" >&2
    return 1
  }

  private_key="$(PATH="$GITHUB_APP_HOST_PATH" python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$AGENT_GITHUB_APP_PRIVATE_KEY_FILE")" || return 1
  workspace="$(cd "${AGENT_WORKSPACE_PATH:-$PWD}" && pwd -P)" || return 1
  case "$private_key" in
    "$workspace"|"$workspace"/*|"$PROJECT_ROOT"|"$PROJECT_ROOT"/*)
      echo "[agent] GitHub App private key must not reside inside the mounted project/workspace" >&2
      return 1 ;;
  esac
  prepare_github_app_identity "$private_key" || return 1

  GITHUB_APP_BROKER_DIR="$RUNTIME_LEASE_DIR/github-app"
  GITHUB_APP_BROKER_SOCKET="$GITHUB_APP_BROKER_DIR/token.sock"
  GITHUB_APP_BROKER_PID_FILE="$GITHUB_APP_BROKER_DIR/service.pid"
  mkdir -p -m 0700 "$GITHUB_APP_BROKER_DIR" || return 1
  chmod 0700 "$GITHUB_APP_BROKER_DIR" || return 1

  fingerprint="$(PATH="$GITHUB_APP_HOST_PATH" python3 "$AGENT_BIN_DIR/agent-github-app-broker" \
    --fingerprint "$AGENT_GITHUB_APP_ID" "$AGENT_GITHUB_INSTALLATION_ID" \
    "$private_key" "${AGENT_GITHUB_APP_REPOSITORIES:-}")" || return 1
  expected_health="ok $fingerprint"
  if github_app_broker_running; then
    if [ "$(PATH="$GITHUB_APP_HOST_PATH" curl -fsS --max-time 2 \
      --unix-socket "$GITHUB_APP_BROKER_SOCKET" http://localhost/health 2>/dev/null)" = "$expected_health" ]; then
      return 0
    fi
    stop_runtime_lease_github_app_broker "$RUNTIME_LEASE_DIR"
    if github_app_broker_running; then
      echo "[agent] could not stop the previous GitHub App broker" >&2
      return 1
    fi
  fi

  # A stale socket from a crashed broker is safe to remove only in our lease.
  rm -f "$GITHUB_APP_BROKER_SOCKET" "$GITHUB_APP_BROKER_PID_FILE"
  (
    umask 077
    export PATH="$GITHUB_APP_HOST_PATH"
    exec python3 "$AGENT_BIN_DIR/agent-github-app-broker" \
      "$GITHUB_APP_BROKER_SOCKET" "$AGENT_GITHUB_APP_ID" "$AGENT_GITHUB_INSTALLATION_ID" \
      "$private_key" "${AGENT_GITHUB_APP_REPOSITORIES:-}" \
      </dev/null > "$GITHUB_APP_BROKER_DIR/service.log" 2>&1
  ) &
  pid=$!
  printf '%s\n' "$pid" > "$GITHUB_APP_BROKER_PID_FILE"

  while [ "$attempt" -lt 50 ]; do
    if github_app_broker_running && [ "$(PATH="$GITHUB_APP_HOST_PATH" curl -fsS --max-time 1 \
      --unix-socket "$GITHUB_APP_BROKER_SOCKET" http://localhost/health 2>/dev/null)" = "$expected_health" ]; then
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  echo "[agent] failed to start GitHub App broker (see $GITHUB_APP_BROKER_DIR/service.log)" >&2
  return 1
}

prepare_github_app_commands() {
  [ "$GITHUB_APP_AUTH_MODE" = app ] || return 0

  cat > "$PATH_GUARD_HOST_DIR/github-app-token" <<'EOF_TOKEN'
#!/bin/sh
set -eu
if [ "$#" -gt 1 ]; then
  echo 'usage: github-app-token [OWNER/REPO]' >&2
  exit 1
fi
if [ -n "${1:-}" ]; then
  set -- --get --data-urlencode "repository=$1"
else
  set --
fi
exec /bin/curl --fail-with-body --silent --show-error --max-time 120 \
  --unix-socket /run/agent-github-app/token.sock "$@" http://localhost/token
EOF_TOKEN

  cat > "$PATH_GUARD_HOST_DIR/github-app-git-credential" <<'EOF_CREDENTIAL'
#!/bin/sh
set -eu
[ "${1:-}" = get ] || exit 0
protocol=""
host=""
path=""
while IFS= read -r line; do
  [ -n "$line" ] || break
  case "$line" in
    protocol=*) protocol="${line#protocol=}" ;;
    host=*) host="${line#host=}" ;;
    path=*) path="${line#path=}" ;;
  esac
done
[ "$protocol" = https ] && [ "$host" = github.com ] || exit 0
path="${path%.git}"
token="$("$(dirname "$0")/github-app-token" "$path")" || exit 1
printf 'username=x-access-token\npassword=%s\n\n' "$token"
EOF_CREDENTIAL

  cp "$AGENT_BIN_DIR/../scripts/image/github-app-gh.sh" "$PATH_GUARD_HOST_DIR/gh"
  chmod 0755 "$PATH_GUARD_HOST_DIR/github-app-token"     "$PATH_GUARD_HOST_DIR/github-app-git-credential" "$PATH_GUARD_HOST_DIR/gh"
}

append_github_app_container_args() {
  [ "$GITHUB_APP_AUTH_MODE" = app ] || return 0
  validate_github_app_identity || return 1
  ARGS+=(
    -v "$GITHUB_APP_BROKER_DIR:/run/agent-github-app:rw${Z_SUFFIX}"
    -e GIT_TERMINAL_PROMPT=0
    -e GIT_CONFIG_COUNT=7
    -e GIT_CONFIG_KEY_0=credential.helper
    -e GIT_CONFIG_VALUE_0=
    -e GIT_CONFIG_KEY_1=credential.helper
    -e 'GIT_CONFIG_VALUE_1=!/run/agent-path-guard/github-app-git-credential'
    -e GIT_CONFIG_KEY_2=url.https://github.com/.insteadOf
    -e 'GIT_CONFIG_VALUE_2=git@github.com:'
    -e GIT_CONFIG_KEY_3=url.https://github.com/.insteadOf
    -e 'GIT_CONFIG_VALUE_3=ssh://git@github.com/'
    -e GIT_CONFIG_KEY_4=user.name
    -e "GIT_CONFIG_VALUE_4=$AGENT_GITHUB_APP_BOT_NAME"
    -e GIT_CONFIG_KEY_5=user.email
    -e "GIT_CONFIG_VALUE_5=$AGENT_GITHUB_APP_BOT_EMAIL"
    -e GIT_CONFIG_KEY_6=credential.https://github.com.useHttpPath
    -e GIT_CONFIG_VALUE_6=true
  )
}
