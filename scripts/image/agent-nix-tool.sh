#!/bin/sh
set -eu

usage() {
  echo "usage: agent-nix-tool <add|env|run> <installable> [-- command args...]" >&2
  exit 1
}

BRIDGE_DIR="${AGENT_NIX_TOOL_HELPER_DIR:-/run/agent-nix-helper}"
REQUESTS_DIR="$BRIDGE_DIR/requests"
RESPONSES_DIR="$BRIDGE_DIR/responses"
TIMEOUT="${AGENT_NIX_TOOL_TIMEOUT:-600}"

helper_request() {
  installable="$1"
  req_id="$(date +%s)-$$-$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%s' "$$")"
  request_file="$REQUESTS_DIR/$req_id.req"
  response_file="$RESPONSES_DIR/$req_id.resp"
  waited=0

  mkdir -p "$REQUESTS_DIR" "$RESPONSES_DIR"
  {
    printf 'command=materialize\n'
    printf 'installable=%s\n' "$installable"
  } > "$request_file"

  while [ "$waited" -lt "$TIMEOUT" ]; do
    if [ -f "$response_file" ]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  echo "[agent] nix tool helper timed out waiting for '$installable'" >&2
  exit 1
}

load_response() {
  response_file="$1"
  status=""
  installable=""
  out_path=""
  bin_path=""
  message=""

  while IFS='=' read -r key value; do
    case "$key" in
      status) status="$value" ;;
      installable) installable="$value" ;;
      out_path) out_path="$value" ;;
      bin_path) bin_path="$value" ;;
      message) message="$value" ;;
    esac
  done < "$response_file"

  rm -f "$response_file"

  if [ "$status" != "ok" ]; then
    echo "[agent] nix tool helper failed for '$installable': $message" >&2
    exit 1
  fi
}

[ "$#" -ge 2 ] || usage
command="$1"
shift
installable="$1"
shift

[ -d "$BRIDGE_DIR" ] || {
  echo "[agent] nix tool helper bridge is unavailable at $BRIDGE_DIR" >&2
  exit 1
}

helper_request "$installable"
load_response "$response_file"

case "$command" in
  add)
    if [ -n "$bin_path" ]; then
      printf '%s\n' "$bin_path"
    else
      printf '%s\n' "$out_path"
    fi
    ;;
  env)
    [ -n "$bin_path" ] || exit 0
    printf 'export PATH="%s:$PATH"\n' "$bin_path"
    ;;
  run)
    [ "$#" -ge 1 ] || usage
    [ "$1" = "--" ] || usage
    shift
    [ "$#" -ge 1 ] || usage
    if [ -n "$bin_path" ]; then
      PATH="$bin_path:$PATH"
    fi
    exec "$@"
    ;;
  *)
    usage
    ;;
esac
