#!/usr/bin/env bash
set -euo pipefail

nix_real="@nixReal@"
nix_shell_real="@nixShellReal@"
sh_real="@shReal@"

usage() {
  echo "usage: agent-compat <command-not-found|nix-wrapper|nix-shell-wrapper|sh-wrapper> ..." >&2
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

  [ "${AGENT_NEED_HELPER:-1}" = "1" ] || return 1
  command -v need >/dev/null 2>&1 || return 1

  resolved_path="$(need materialize "$installable")" || return 1
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

extract_missing_command() {
  local stderr_file="$1"
  local missing_command=""

  missing_command="$(sed -n \
    -e 's/^.*: \([^ :][^:]*\): command not found$/\1/p' \
    -e 's/^.*: \([^ :][^:]*\): not found$/\1/p' \
    "$stderr_file" | head -n 1)"

  [ -n "$missing_command" ] || return 1
  printf '%s\n' "$missing_command"
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

handle_sh_wrapper() {
  local shell_flag="${1:-}"
  local shell_command="${2:-}"
  local tmp_dir=""
  local stdout_file=""
  local stderr_file=""
  local status=0
  local missing_command=""
  local installable=""
  local bin_dir=""

  case "$shell_flag" in
    -c|-lc)
      ;;
    *)
      exec "$sh_real" "$@"
      ;;
  esac

  [ "$#" -ge 2 ] || exec "$sh_real" "$@"
  shift 2

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh.XXXXXX")"
  stdout_file="$tmp_dir/stdout"
  stderr_file="$tmp_dir/stderr"
  trap 'rm -rf "$tmp_dir"' EXIT

  set +e
  AGENT_NEED_WRAPPER_HANDLING=1 "$sh_real" "$shell_flag" "$shell_command" "$@" >"$stdout_file" 2>"$stderr_file"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    cat "$stdout_file"
    cat "$stderr_file" >&2
    exit 0
  fi

  if [ "$status" -eq 127 ]; then
    missing_command="$(extract_missing_command "$stderr_file" || true)"
  fi

  cat "$stdout_file"
  cat "$stderr_file" >&2
  if [ "$status" -eq 127 ] && [ -n "$missing_command" ] && command -v need >/dev/null 2>&1; then
    if ! grep -q "Run once in this sandbox:" "$stderr_file" 2>/dev/null; then
      /bin/need missing "$missing_command" || true
    fi
  fi
  exit "$status"
}

command_name="${1:-}"
shift || true

case "$command_name" in
  command-not-found)
    [ "$#" -ge 1 ] || exit 127
    exec /bin/need missing "$@"
    ;;
  nix-wrapper)
    handle_nix_shell "$@"
    ;;
  nix-shell-wrapper)
    handle_legacy_nix_shell "$@"
    ;;
  sh-wrapper)
    handle_sh_wrapper "$@"
    ;;
  *)
    usage
    ;;
esac
