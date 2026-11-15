# Opt-in, host-only GitHub App authentication for unattended agents.
GITHUB_APP_AUTH_MODE="none"
GITHUB_APP_BROKER_DIR=""
GITHUB_APP_BROKER_SOCKET=""
GITHUB_APP_BROKER_PID_FILE=""

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

prepare_github_app_auth() {
  local private_key="" workspace="" attempt=0 pid=""
  GITHUB_APP_AUTH_MODE="${AGENT_GITHUB_AUTH:-none}"
  case "$GITHUB_APP_AUTH_MODE" in
    none|0) return 0 ;;
    app) ;;
    *) echo "[agent] AGENT_GITHUB_AUTH must be 'none' or 'app'" >&2; return 1 ;;
  esac

  command -v python3 >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1     && command -v curl >/dev/null 2>&1 || {
    echo "[agent] GitHub App authentication requires python3, openssl, and curl on the host" >&2
    return 1
  }
  case "${AGENT_GITHUB_APP_ID:-}" in
    ""|*[!0-9]*) echo "[agent] AGENT_GITHUB_APP_ID must be numeric" >&2; return 1 ;;
  esac
  case "${AGENT_GITHUB_INSTALLATION_ID:-}" in
    ""|*[!0-9]*) echo "[agent] AGENT_GITHUB_INSTALLATION_ID must be numeric" >&2; return 1 ;;
  esac
  [ -n "${AGENT_GITHUB_APP_PRIVATE_KEY_FILE:-}" ] && [ -f "$AGENT_GITHUB_APP_PRIVATE_KEY_FILE" ]     && [ -r "$AGENT_GITHUB_APP_PRIVATE_KEY_FILE" ] || {
    echo "[agent] AGENT_GITHUB_APP_PRIVATE_KEY_FILE must name a readable host-side key file" >&2
    return 1
  }

  private_key="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$AGENT_GITHUB_APP_PRIVATE_KEY_FILE")"
  workspace="$(cd "${AGENT_WORKSPACE_PATH:-$PWD}" && pwd -P)" || return 1
  case "$private_key" in
    "$workspace"|"$workspace"/*|"$PROJECT_ROOT"|"$PROJECT_ROOT"/*)
      echo "[agent] GitHub App private key must not reside inside the mounted project/workspace" >&2
      return 1 ;;
  esac
  if [ -n "${AGENT_GITHUB_APP_BOT_NAME:-}" ] && [ -z "${AGENT_GITHUB_APP_BOT_EMAIL:-}" ]     || [ -n "${AGENT_GITHUB_APP_BOT_EMAIL:-}" ] && [ -z "${AGENT_GITHUB_APP_BOT_NAME:-}" ]; then
    echo "[agent] set both AGENT_GITHUB_APP_BOT_NAME and AGENT_GITHUB_APP_BOT_EMAIL" >&2
    return 1
  fi

  GITHUB_APP_BROKER_DIR="$RUNTIME_LEASE_DIR/github-app"
  GITHUB_APP_BROKER_SOCKET="$GITHUB_APP_BROKER_DIR/token.sock"
  GITHUB_APP_BROKER_PID_FILE="$GITHUB_APP_BROKER_DIR/service.pid"
  mkdir -p -m 0700 "$GITHUB_APP_BROKER_DIR" || return 1
  chmod 0700 "$GITHUB_APP_BROKER_DIR" || return 1

  if github_app_broker_running && curl -fsS --max-time 2     --unix-socket "$GITHUB_APP_BROKER_SOCKET" http://localhost/health >/dev/null 2>&1; then
    return 0
  fi

  # A stale socket from a crashed broker is safe to remove only in our lease.
  rm -f "$GITHUB_APP_BROKER_SOCKET" "$GITHUB_APP_BROKER_PID_FILE"
  (
    umask 077
    exec python3 "$AGENT_BIN_DIR/agent-github-app-broker"       "$GITHUB_APP_BROKER_SOCKET" "$AGENT_GITHUB_APP_ID" "$AGENT_GITHUB_INSTALLATION_ID"       "$private_key" "${AGENT_GITHUB_APP_REPOSITORIES:-}"       </dev/null > "$GITHUB_APP_BROKER_DIR/service.log" 2>&1
  ) &
  pid=$!
  printf '%s\n' "$pid" > "$GITHUB_APP_BROKER_PID_FILE"

  while [ "$attempt" -lt 50 ]; do
    if github_app_broker_running && curl -fsS --max-time 1       --unix-socket "$GITHUB_APP_BROKER_SOCKET" http://localhost/health >/dev/null 2>&1; then
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
exec /bin/curl --fail --silent --show-error --max-time 30 \
  --unix-socket /run/agent-github-app/token.sock http://localhost/token
EOF_TOKEN

  cat > "$PATH_GUARD_HOST_DIR/github-app-git-credential" <<'EOF_CREDENTIAL'
#!/bin/sh
set -eu
[ "${1:-}" = get ] || exit 0
protocol=""
host=""
while IFS= read -r line; do
  [ -n "$line" ] || break
  case "$line" in
    protocol=*) protocol="${line#protocol=}" ;;
    host=*) host="${line#host=}" ;;
  esac
done
[ "$protocol" = https ] && [ "$host" = github.com ] || exit 0
token="$(/run/agent-path-guard/github-app-token)" || exit 1
printf 'username=x-access-token\npassword=%s\n\n' "$token"
EOF_CREDENTIAL

  cat > "$PATH_GUARD_HOST_DIR/gh" <<'EOF_GH'
#!/bin/sh
set -eu
export GH_TOKEN="$(/run/agent-path-guard/github-app-token)"
export GH_CONFIG_DIR=/cache/agent-github-app/gh
export GH_HOST=github.com
mkdir -p "$GH_CONFIG_DIR"
exec /bin/gh "$@"
EOF_GH
  chmod 0755 "$PATH_GUARD_HOST_DIR/github-app-token"     "$PATH_GUARD_HOST_DIR/github-app-git-credential" "$PATH_GUARD_HOST_DIR/gh"
}

append_github_app_container_args() {
  [ "$GITHUB_APP_AUTH_MODE" = app ] || return 0
  ARGS+=(
    -v "$GITHUB_APP_BROKER_DIR:/run/agent-github-app:rw${Z_SUFFIX}"
    -e GIT_TERMINAL_PROMPT=0
    -e GIT_CONFIG_COUNT=6
    -e GIT_CONFIG_KEY_0=credential.helper
    -e GIT_CONFIG_VALUE_0=
    -e GIT_CONFIG_KEY_1=credential.helper
    -e 'GIT_CONFIG_VALUE_1=!/run/agent-path-guard/github-app-git-credential'
    -e GIT_CONFIG_KEY_2=url.https://github.com/.insteadOf
    -e 'GIT_CONFIG_VALUE_2=git@github.com:'
    -e GIT_CONFIG_KEY_3=url.https://github.com/.insteadOf
    -e 'GIT_CONFIG_VALUE_3=ssh://git@github.com/'
    -e GIT_CONFIG_KEY_4=user.name
    -e "GIT_CONFIG_VALUE_4=${AGENT_GITHUB_APP_BOT_NAME:-Coding Agent}"
    -e GIT_CONFIG_KEY_5=user.email
    -e "GIT_CONFIG_VALUE_5=${AGENT_GITHUB_APP_BOT_EMAIL:-coding-agent@users.noreply.github.com}"
  )
}
