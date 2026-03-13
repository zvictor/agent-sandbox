#!/usr/bin/env bash
set -euo pipefail

nix_real="@nixReal@"
nix_shell_real="@nixShellReal@"

usage() {
  echo "usage: agent-compat <command-not-found|run-command|nix-wrapper|nix-shell-wrapper> ..." >&2
  exit 1
}

resolve_wrapper_real() {
  local wrapper_name="$1"
  local wrapper_path="/bin/$wrapper_name"

  if [ ! -e "$wrapper_path" ]; then
    return 0
  fi

  readlink -f "$wrapper_path" 2>/dev/null || printf '%s\n' "$wrapper_path"
}

find_existing_command() {
  local command_name="$1"
  local wrapper_name="${2:-}"
  local wrapper_real=""
  local candidate=""
  local candidate_real=""
  local path_dir=""

  if [ -n "$wrapper_name" ]; then
    wrapper_real="$(resolve_wrapper_real "$wrapper_name")"
  fi

  IFS=':' read -r -a path_entries <<< "${PATH:-}"
  for path_dir in "${path_entries[@]}"; do
    [ -n "$path_dir" ] || path_dir="."
    candidate="$path_dir/$command_name"
    [ -x "$candidate" ] || continue

    candidate_real="$(readlink -f "$candidate" 2>/dev/null || printf '%s\n' "$candidate")"
    if [ -z "$wrapper_real" ] || [ "$candidate_real" != "$wrapper_real" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

installable_for_command() {
  local command_name="$1"

  case "$command_name" in
    docker)
      printf '%s\n' 'nixpkgs#docker-client'
      ;;
    docker-compose)
      printf '%s\n' 'nixpkgs#docker-compose'
      ;;
    podman)
      printf '%s\n' 'nixpkgs#podman'
      ;;
    *)
      if printf '%s\n' "$command_name" | grep -Eq '^[A-Za-z0-9._+-]+$'; then
        printf 'nixpkgs#%s\n' "$command_name"
      else
        return 1
      fi
      ;;
  esac
}

resolve_bin_dir() {
  local resolved_path="$1"
  local first_exec=""

  if [ -d "$resolved_path" ]; then
    first_exec="$(find "$resolved_path" -mindepth 1 -maxdepth 1 -type f -perm -111 2>/dev/null | head -n1 || true)"
    if [ -n "$first_exec" ]; then
      printf '%s\n' "$resolved_path"
      return 0
    fi
  fi

  if [ -d "$resolved_path/bin" ]; then
    first_exec="$(find "$resolved_path/bin" -mindepth 1 -maxdepth 1 -type f -perm -111 2>/dev/null | head -n1 || true)"
    if [ -n "$first_exec" ]; then
      printf '%s\n' "$resolved_path/bin"
      return 0
    fi
  fi

  return 1
}

materialize_installable_bin_dir() {
  local installable="$1"
  local resolved_path=""

  [ "${AGENT_NIX_TOOL_HELPER:-1}" = "1" ] || return 1
  command -v agent-nix-tool >/dev/null 2>&1 || return 1

  resolved_path="$(agent-nix-tool add "$installable" 2>/dev/null)" || return 1
  resolve_bin_dir "$resolved_path"
}

build_path_prefix() {
  local installable=""
  local bin_dir=""
  local path_prefix=""

  for installable in "$@"; do
    bin_dir="$(materialize_installable_bin_dir "$installable")" || return 1
    path_prefix="${path_prefix:+$path_prefix:}$bin_dir"
  done

  printf '%s\n' "$path_prefix"
}

run_materialized_command() {
  local command_name="$1"
  shift

  local existing_path=""
  local installable=""
  local bin_dir=""

  existing_path="$(find_existing_command "$command_name" "$command_name" || true)"
  if [ -n "$existing_path" ]; then
    exec "$existing_path" "$@"
  fi

  installable="$(installable_for_command "$command_name" || true)"
  if [ -z "$installable" ]; then
    exit 127
  fi

  bin_dir="$(materialize_installable_bin_dir "$installable" || true)"
  if [ -z "$bin_dir" ] || [ ! -x "$bin_dir/$command_name" ]; then
    echo "[agent] could not materialize '$command_name' from $installable" >&2
    exit 127
  fi

  exec "$bin_dir/$command_name" "$@"
}

run_with_installables() {
  local installables=()
  local path_prefix=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --)
        shift
        break
        ;;
      *)
        installables+=( "$1" )
        shift
        ;;
    esac
  done

  [ "${#installables[@]}" -gt 0 ] || return 1
  [ "$#" -gt 0 ] || return 1

  path_prefix="$(build_path_prefix "${installables[@]}")" || return 1
  PATH="$path_prefix:$PATH" exec "$@"
}

shell_with_installables() {
  local installables=( "$@" )
  local path_prefix=""
  local shell_cmd="${SHELL:-/bin/bash}"

  [ "${#installables[@]}" -gt 0 ] || return 1

  path_prefix="$(build_path_prefix "${installables[@]}")" || return 1
  PATH="$path_prefix:$PATH" exec "$shell_cmd"
}

handle_nix_shell() {
  local passthrough=()
  local installables=()
  local saw_shell="0"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      shell)
        saw_shell="1"
        shift
        break
        ;;
      --extra-experimental-features)
        [ "$#" -ge 2 ] || exec "$nix_real" "${passthrough[@]}" "$@"
        passthrough+=( "$1" "$2" )
        shift 2
        ;;
      --option)
        [ "$#" -ge 3 ] || exec "$nix_real" "${passthrough[@]}" "$@"
        passthrough+=( "$1" "$2" "$3" )
        shift 3
        ;;
      *)
        exec "$nix_real" "${passthrough[@]}" "$@"
        ;;
    esac
  done

  [ "$saw_shell" = "1" ] || exec "$nix_real" "${passthrough[@]}" "$@"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --command|-c)
        shift
        [ "$#" -gt 0 ] || exec "$nix_real" "${passthrough[@]}" shell "${installables[@]}"
        [ "${#installables[@]}" -gt 0 ] || exec "$nix_real" "${passthrough[@]}" shell "$@"
        run_with_installables "${installables[@]}" -- "$@"
        ;;
      --)
        shift
        [ "$#" -gt 0 ] || exec "$nix_real" "${passthrough[@]}" shell "${installables[@]}" --
        [ "${#installables[@]}" -gt 0 ] || exec "$nix_real" "${passthrough[@]}" shell -- "$@"
        run_with_installables "${installables[@]}" -- "$@"
        ;;
      -*)
        exec "$nix_real" "${passthrough[@]}" shell "$@"
        ;;
      *)
        installables+=( "$1" )
        shift
        ;;
    esac
  done

  [ "${#installables[@]}" -gt 0 ] || exec "$nix_real" "${passthrough[@]}" shell
  shell_with_installables "${installables[@]}"
}

handle_legacy_nix_shell() {
  local packages=()
  local shell_command=""

  [ "$#" -gt 0 ] || exec "$nix_shell_real"
  [ "$1" = "-p" ] || exec "$nix_shell_real" "$@"
  shift

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run|--command)
        [ "$#" -ge 2 ] || exec "$nix_shell_real" -p "${packages[@]}" "$@"
        shell_command="$2"
        shift 2
        [ "$#" -eq 0 ] || exec "$nix_shell_real" -p "${packages[@]}" "$@"
        ;;
      --)
        shift
        [ "$#" -gt 0 ] || exec "$nix_shell_real" -p "${packages[@]}" --
        run_with_installables "${packages[@]/#/nixpkgs#}" -- "$@"
        ;;
      -*)
        exec "$nix_shell_real" -p "${packages[@]}" "$@"
        ;;
      *)
        packages+=( "$1" )
        shift
        ;;
    esac
  done

  [ "${#packages[@]}" -gt 0 ] || exec "$nix_shell_real"
  if [ -n "$shell_command" ]; then
    local path_prefix=""
    path_prefix="$(build_path_prefix "${packages[@]/#/nixpkgs#}")" || exit 1
    PATH="$path_prefix:$PATH" exec /bin/sh -lc "$shell_command"
  fi

  shell_with_installables "${packages[@]/#/nixpkgs#}"
}

command_name="${1:-}"
shift || true

case "$command_name" in
  command-not-found)
    [ "$#" -ge 1 ] || exit 127
    run_materialized_command "$@"
    ;;
  run-command)
    [ "$#" -ge 1 ] || usage
    run_materialized_command "$@"
    ;;
  nix-wrapper)
    handle_nix_shell "$@"
    ;;
  nix-shell-wrapper)
    handle_legacy_nix_shell "$@"
    ;;
  *)
    usage
    ;;
esac
