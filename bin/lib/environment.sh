PROJECT_CONFIG_FILE=""
EFFECTIVE_TOOLS_LIST=""
EFFECTIVE_TOOLS_SOURCE=""
PROJECT_ROOT_SOURCE=""

trim_whitespace() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

is_project_config_key_allowed() {
  case "$1" in
    AGENT_*|CODEX_*|CLAUDE_*|OPENCODE_*|COMMANDCODE_*|OMP_*|PI_*|CCHV_*|TESTCONTAINERS_*|OPENAI_*|ANTHROPIC_*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Expand $VAR and ${VAR} patterns in a string using current environment
expand_config_variables() {
  local value="$1"
  local result="$value"
  local tmpfile
  local iteration=0

  tmpfile=$(mktemp)

  while [ $iteration -lt 10 ]; do
    local prev="$result"
    iteration=$((iteration + 1))

    > "$tmpfile"

    env | awk -F= 'NF >= 1 {print length($1), $1}' | sort -rn | while read -r len var_name; do
      case "$var_name" in
        "" | [0-9]* | *[!a-zA-Z0-9_]* ) continue ;;
      esac

      local var_val
      var_val=$(eval printf '%s' "\$$var_name" 2>/dev/null) || continue

      case "$var_val" in
        *"\$$var_name"* | *"\${$var_name}"* ) continue ;;
      esac

      # Escape sed RHS metacharacters: backslash, ampersand, and the delimiter (|).
      # Order: backslash first to prevent double-escaping.
      var_val=$(printf '%s' "$var_val" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g')

      printf 's|\\${%s}|%s|g\n' "$var_name" "$var_val"
      printf 's|\\$%s$|%s|\n' "$var_name" "$var_val"
      printf 's|\\$%s\\([^(a-zA-Z0-9_]\\)|%s\\1|g\n' "$var_name" "$var_val"
    done > "$tmpfile"

    result=$(printf '%s' "$result" | sed -f "$tmpfile")

    [ "$result" = "$prev" ] && break
  done

  rm -f "$tmpfile"
  printf '%s' "$result"
}

resolve_project_config_file() {
  PROJECT_CONFIG_FILE=""

  if [ -n "${AGENT_PROJECT_CONFIG_FILE:-}" ]; then
    PROJECT_CONFIG_FILE="$AGENT_PROJECT_CONFIG_FILE"
    return 0
  fi

  if [ -f "$PROJECT_ROOT/.agent-sandbox.env" ]; then
    PROJECT_CONFIG_FILE="$PROJECT_ROOT/.agent-sandbox.env"
    return 0
  fi
}

load_project_config() {
  local raw_line=""
  local line=""
  local key=""
  local value=""

  resolve_project_config_file
  [ -n "$PROJECT_CONFIG_FILE" ] || return 0
  [ -f "$PROJECT_CONFIG_FILE" ] || return 0

  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line="$(trim_whitespace "$raw_line")"
    [ -n "$line" ] || continue
    case "$line" in
      \#*) continue ;;
      *=*) ;;
      *)
        echo "[agent] ignoring invalid config line in $PROJECT_CONFIG_FILE: $raw_line" >&2
        continue
        ;;
    esac

    key="$(trim_whitespace "${line%%=*}")"
    value="$(trim_whitespace "${line#*=}")"

    if ! printf '%s\n' "$key" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then
      echo "[agent] ignoring invalid config key '$key' in $PROJECT_CONFIG_FILE" >&2
      continue
    fi

    if ! is_project_config_key_allowed "$key"; then
      echo "[agent] ignoring unsupported project config key '$key' in $PROJECT_CONFIG_FILE" >&2
      continue
    fi

    if [ "${value#\"}" != "$value" ] && [ "${value%\"}" != "$value" ] && [ "${#value}" -ge 2 ]; then
      value="${value#\"}"
      value="${value%\"}"
    elif [ "${value#\'}" != "$value" ] && [ "${value%\'}" != "$value" ] && [ "${#value}" -ge 2 ]; then
      value="${value#\'}"
      value="${value%\'}"
    fi

    # Expand variable references like $VAR and ${VAR}
    value=$(expand_config_variables "$value")

    if [ -z "${!key+x}" ]; then
      printf -v "$key" '%s' "$value"
      export "$key"
    fi
  done < "$PROJECT_CONFIG_FILE"
}

resolve_runtime() {
  if ! resolve_runtime_state; then
    echo "[agent] $RUNTIME_ERROR" >&2
    exit 1
  fi
}

resolve_sandbox_profile() {
  SANDBOX_PROFILE="${AGENT_SANDBOX_PROFILE:-default}"
  case "$SANDBOX_PROFILE" in
    ""|default)
      SANDBOX_PROFILE="default"
      ;;
    firecracker-host|rootless-linux)
      ;;
    *)
      echo "[agent] invalid AGENT_SANDBOX_PROFILE='$SANDBOX_PROFILE' (expected: default, rootless-linux, or firecracker-host)" >&2
      exit 1
      ;;
  esac
  AGENT_SANDBOX_PROFILE="$SANDBOX_PROFILE"
  export AGENT_SANDBOX_PROFILE
}

resolve_runtime_state() {
  RUNTIME_REQUESTED="${AGENT_RUNTIME:-${CODEX_RUNTIME:-}}"
  RUNTIME_ERROR=""

  if [ "${SANDBOX_PROFILE:-${AGENT_SANDBOX_PROFILE:-default}}" = "firecracker-host" ]; then
    if [ -n "$RUNTIME_REQUESTED" ] && [ "$RUNTIME_REQUESTED" != "podman" ]; then
      RUNTIME="unavailable"
      RUNTIME_ERROR="AGENT_SANDBOX_PROFILE=firecracker-host supports only AGENT_RUNTIME=podman"
      return 1
    fi
    if command -v podman >/dev/null 2>&1; then
      RUNTIME="podman"
      return 0
    fi
    RUNTIME="unavailable"
    RUNTIME_ERROR="AGENT_SANDBOX_PROFILE=firecracker-host requires podman"
    return 1
  fi

  if [ "${SANDBOX_PROFILE:-${AGENT_SANDBOX_PROFILE:-default}}" = "rootless-linux" ]; then
    if [ -n "$RUNTIME_REQUESTED" ] && [ "$RUNTIME_REQUESTED" != "podman" ]; then
      RUNTIME="unavailable"
      RUNTIME_ERROR="AGENT_SANDBOX_PROFILE=rootless-linux supports only AGENT_RUNTIME=podman"
      return 1
    fi
    if command -v podman >/dev/null 2>&1; then
      RUNTIME="podman"
      return 0
    fi
    RUNTIME="unavailable"
    RUNTIME_ERROR="AGENT_SANDBOX_PROFILE=rootless-linux requires podman"
    return 1
  fi

  if [ -n "$RUNTIME_REQUESTED" ]; then
    RUNTIME="$RUNTIME_REQUESTED"
    if command -v "$RUNTIME" >/dev/null 2>&1; then
      return 0
    fi

    RUNTIME_ERROR="requested runtime '$RUNTIME' is not available"
    return 1
  fi

  if command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
    return 0
  fi

  RUNTIME="unavailable"
  RUNTIME_ERROR="neither podman nor docker is available in PATH"
  return 1
}

firecracker_host_preflight_fail() {
  echo "[agent] firecracker-host preflight failed: $*" >&2
  exit 1
}

firecracker_host_workspace_path() {
  local workspace_path="${AGENT_WORKSPACE_PATH:-$PWD}"

  if [ ! -d "$workspace_path" ]; then
    firecracker_host_preflight_fail "workspace path is not a directory: $workspace_path"
  fi

  (
    cd "$workspace_path" &&
    pwd -P
  )
}

preflight_firecracker_host_profile() {
  local podman_rootless=""
  local workspace_path=""

  [ "${SANDBOX_PROFILE:-${AGENT_SANDBOX_PROFILE:-default}}" = "firecracker-host" ] || return 0

  if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != "root" ]; then
    firecracker_host_preflight_fail "do not run the launcher with sudo; run it as the operator user, because firecracker-host invokes sudo -n podman internally"
  fi

  [ "$OS_NAME" = "Linux" ] || firecracker_host_preflight_fail "Linux is required"
  command -v sudo >/dev/null 2>&1 || firecracker_host_preflight_fail "sudo is not installed"
  command -v podman >/dev/null 2>&1 || firecracker_host_preflight_fail "podman is not installed"

  if ! sudo -n true >/dev/null 2>&1; then
    firecracker_host_preflight_fail "sudo -n must work without prompting"
  fi

  if ! sudo -n podman info >/dev/null 2>&1; then
    firecracker_host_preflight_fail "sudo -n podman info must work"
  fi

  podman_rootless="$(sudo -n podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
  if [ "$podman_rootless" = "true" ]; then
    firecracker_host_preflight_fail "rootful podman is required"
  fi

  if ! sudo -n sh -c 'test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm'; then
    firecracker_host_preflight_fail "/dev/kvm must be present and readable/writable by root"
  fi

  if ! sudo -n sh -c 'test -c /dev/net/tun && test -r /dev/net/tun && test -w /dev/net/tun'; then
    firecracker_host_preflight_fail "/dev/net/tun must be present and readable/writable by root"
  fi

  if ! sudo -n sh -c 'test -f /sys/fs/cgroup/cgroup.controllers'; then
    firecracker_host_preflight_fail "cgroup v2 must be mounted at /sys/fs/cgroup"
  fi

  if ! sudo -n sh -c 'dir="$(mktemp -d /sys/fs/cgroup/agent-sandbox-firecracker.XXXXXX)" && rmdir "$dir"'; then
    firecracker_host_preflight_fail "root must be able to create cgroup v2 child directories"
  fi

  if ! sudo -n sh -c 'dir="$(mktemp -d /sys/fs/cgroup/agent-sandbox-firecracker.XXXXXX)" || exit 1; trap "rmdir \"$dir\"" EXIT; printf 0 > "$dir/cgroup.freeze"'; then
    firecracker_host_preflight_fail "root must be able to write cgroup v2 control files"
  fi

  workspace_path="$(firecracker_host_workspace_path)"
  if ! sudo -n sh -c 'file="$1/.agent-sandbox-root-write-test.$$"; touch "$file" && chown 0:0 "$file" && rm -f "$file"' sh "$workspace_path"; then
    firecracker_host_preflight_fail "root must be able to write and chown files under the workspace"
  fi
}

rootless_linux_preflight_fail() {
  echo "[agent] rootless-linux preflight failed: $*" >&2
  exit 1
}

preflight_rootless_linux_profile() {
  local delegation_output=""
  local podman_rootless=""
  local delegated_probe=""

  [ "${SANDBOX_PROFILE:-${AGENT_SANDBOX_PROFILE:-default}}" = "rootless-linux" ] || return 0

  [ "$OS_NAME" = "Linux" ] || rootless_linux_preflight_fail "Linux is required"
  [ "$(id -u)" != "0" ] || rootless_linux_preflight_fail "run the launcher as an unprivileged user"

  case "${AGENT_ALLOW_SUDO:-0}" in
    ""|0) ;;
    1) rootless_linux_preflight_fail "AGENT_ALLOW_SUDO must remain disabled" ;;
    *) rootless_linux_preflight_fail "AGENT_ALLOW_SUDO must be 0 or 1" ;;
  esac

  [ -z "${AGENT_EXTRA_MOUNTS:-}" ] \
    || rootless_linux_preflight_fail "AGENT_EXTRA_MOUNTS is not supported"
  [ -z "${AGENT_AUTO_MOUNT_DIRS:-}" ] \
    || rootless_linux_preflight_fail "AGENT_AUTO_MOUNT_DIRS is not supported"
  [ -z "${AGENT_EXTRA_DEVICES:-}" ] \
    || rootless_linux_preflight_fail "AGENT_EXTRA_DEVICES is not supported"
  [ "${AGENT_ALLOW_KVM:-0}" = "0" ] \
    || rootless_linux_preflight_fail "AGENT_ALLOW_KVM is not supported"
  [ "${AGENT_ALLOW_NIX_DAEMON_SOCKET:-0}" = "0" ] \
    || rootless_linux_preflight_fail "AGENT_ALLOW_NIX_DAEMON_SOCKET is not supported"

  command -v podman >/dev/null 2>&1 || rootless_linux_preflight_fail "podman is not installed"
  command -v systemctl >/dev/null 2>&1 || rootless_linux_preflight_fail "systemctl is not installed"
  command -v systemd-run >/dev/null 2>&1 || rootless_linux_preflight_fail "systemd-run is not installed"
  command -v unshare >/dev/null 2>&1 || rootless_linux_preflight_fail "unshare is not installed"

  [ -n "${XDG_RUNTIME_DIR:-}" ] || rootless_linux_preflight_fail "XDG_RUNTIME_DIR is not set"
  [ -d "$XDG_RUNTIME_DIR" ] && [ -r "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ] && [ -x "$XDG_RUNTIME_DIR" ] \
    || rootless_linux_preflight_fail "XDG_RUNTIME_DIR must be a private, usable user runtime directory"
  [ "$(stat -c '%u' "$XDG_RUNTIME_DIR" 2>/dev/null || true)" = "$(id -u)" ] \
    || rootless_linux_preflight_fail "XDG_RUNTIME_DIR must be owned by the launcher user"
  [ "$(stat -c '%a' "$XDG_RUNTIME_DIR" 2>/dev/null || true)" = "700" ] \
    || rootless_linux_preflight_fail "XDG_RUNTIME_DIR must have mode 0700"

  if ! systemctl --user show-environment >/dev/null 2>&1; then
    rootless_linux_preflight_fail "an active systemd user service manager is required"
  fi

  if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
    rootless_linux_preflight_fail "cgroup v2 must be mounted at /sys/fs/cgroup"
  fi

  delegated_probe='set -eu
fail() {
  printf '\''%s\n'\'' "$*" >&2
  exit 1
}
cgroup_path="$(awk -F: '\''$1 == "0" { print $3; exit }'\'' /proc/self/cgroup)"
[ -n "$cgroup_path" ] || fail "could not resolve the transient scope cgroup"
scope_path="/sys/fs/cgroup$cgroup_path"
[ -w "$scope_path/cgroup.procs" ] \
  || fail "transient scope cgroup.procs is not writable: $scope_path/cgroup.procs"
[ -w "$scope_path/cgroup.subtree_control" ] \
  || fail "transient scope cgroup.subtree_control is not writable: $scope_path/cgroup.subtree_control"
controllers="$(cat "$scope_path/cgroup.controllers")" \
  || fail "could not read the transient scope controllers"
for controller in cpu memory pids; do
  case " $controllers " in
    *" $controller "*) ;;
    *) fail "$controller is not available to the transient scope (available: ${controllers:-none})" ;;
  esac
done

# Delegate= makes controllers available at the scope boundary, but cgroup v2
# requires the delegatee to move its own process below that boundary before it
# may enable domain controllers for child cgroups.
payload_path="$scope_path/rootless-linux-payload.$$"
probe_path="$scope_path/rootless-linux-probe.$$"
mkdir "$payload_path" \
  || fail "could not create a payload cgroup below the transient scope"
printf '\''%s\n'\'' "$$" > "$payload_path/cgroup.procs" \
  || fail "could not move the delegation probe below the transient scope boundary"
printf '\''+cpu +memory +pids\n'\'' > "$scope_path/cgroup.subtree_control" \
  || fail "could not enable CPU, memory, and PID controllers below the transient scope"
mkdir "$probe_path" \
  || fail "could not create a controlled child cgroup below the transient scope"
printf '\''max\n'\'' > "$probe_path/cpu.max" \
  || fail "the delegated CPU controller is not writable"
printf '\''max\n'\'' > "$probe_path/memory.max" \
  || fail "the delegated memory controller is not writable"
printf '\''max\n'\'' > "$probe_path/pids.max" \
  || fail "the delegated PID controller is not writable"
rmdir "$probe_path" \
  || fail "could not remove the empty controlled child cgroup"'

  if ! delegation_output="$(systemd-run --user --scope --quiet --collect \
    --property='Delegate=cpu memory pids' -- \
    sh -c "$delegated_probe" 2>&1)"; then
    if [ -n "$delegation_output" ]; then
      printf '%s\n' "$delegation_output" | while IFS= read -r diagnostic; do
        printf '[agent] rootless-linux delegation probe: %s\n' "$diagnostic" >&2
      done
    fi
    rootless_linux_preflight_fail "the user manager must delegate writable CPU, memory, and PID cgroup-v2 controls"
  fi

  if ! unshare --user --map-root-user true >/dev/null 2>&1; then
    rootless_linux_preflight_fail "unprivileged user namespaces are unavailable"
  fi

  if ! podman info >/dev/null 2>&1; then
    rootless_linux_preflight_fail "podman info failed for the launcher user"
  fi
  podman_rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
  [ "$podman_rootless" = "true" ] || rootless_linux_preflight_fail "rootless podman is required"
}

resolve_lock_args() {
  LOCK_ARGS=()
  SANDBOX_LOCK_PATH=""
  case "$SANDBOX_FLAKE" in
    path:*)
      SANDBOX_LOCK_PATH="${SANDBOX_FLAKE#path:}"
      ;;
    /*|./*|../*)
      SANDBOX_LOCK_PATH="$SANDBOX_FLAKE"
      ;;
  esac
  if [ -n "$SANDBOX_LOCK_PATH" ] && [ -f "$SANDBOX_LOCK_PATH/flake.lock" ]; then
    LOCK_ARGS+=(--no-update-lock-file)
  fi
}

resolve_project_paths() {
  local git_root=""

  if [ -n "${AGENT_PROJECT_ROOT:-}" ]; then
    PROJECT_ROOT="$AGENT_PROJECT_ROOT"
    PROJECT_ROOT_SOURCE="env"
  else
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$git_root" ]; then
      PROJECT_ROOT="$git_root"
      PROJECT_ROOT_SOURCE="git"
    else
      PROJECT_ROOT="$(pwd)"
      PROJECT_ROOT_SOURCE="cwd"
    fi
  fi
  PROJECT_NIX_DIR="${AGENT_PROJECT_NIX_DIR:-$PROJECT_ROOT/nix}"
}

resolve_host_home() {
  local candidate_home=""
  local project_root_tail=""

  HOST_HOME="${AGENT_HOST_HOME:-$HOME}"
  if [ -z "$HOST_HOME" ] || [ "$HOST_HOME" = "/cache" ] || [ ! -d "$HOST_HOME" ]; then
    HOST_HOME=""

    if command -v getent >/dev/null 2>&1; then
      HOST_HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
    fi

    if [ -z "$HOST_HOME" ] && [ -n "${USER:-}" ] && [ -d "/home/$USER" ]; then
      HOST_HOME="/home/$USER"
    fi

    if [ -z "$HOST_HOME" ] && [ -n "${LOGNAME:-}" ] && [ -d "/home/$LOGNAME" ]; then
      HOST_HOME="/home/$LOGNAME"
    fi

    if [ -z "$HOST_HOME" ]; then
      while IFS= read -r candidate_home; do
        [ -n "$candidate_home" ] || continue
        HOST_HOME="$candidate_home"
        break
      done < <(find /home -mindepth 1 -maxdepth 1 -type d -user "$(id -u)" 2>/dev/null)
    fi

    if [ -z "$HOST_HOME" ] && [ -d "/Users" ]; then
      while IFS= read -r candidate_home; do
        [ -n "$candidate_home" ] || continue
        HOST_HOME="$candidate_home"
        break
      done < <(find /Users -mindepth 1 -maxdepth 1 -type d -user "$(id -u)" 2>/dev/null)
    fi

    if [ -z "$HOST_HOME" ]; then
      case "$PROJECT_ROOT" in
        /home/*)
          project_root_tail="${PROJECT_ROOT#/home/}"
          candidate_home="/home/${project_root_tail%%/*}"
          if [ -d "$candidate_home" ]; then
            HOST_HOME="$candidate_home"
          fi
          ;;
        /Users/*)
          project_root_tail="${PROJECT_ROOT#/Users/}"
          candidate_home="/Users/${project_root_tail%%/*}"
          if [ -d "$candidate_home" ]; then
            HOST_HOME="$candidate_home"
          fi
          ;;
      esac
    fi
  fi
  if [ -z "$HOST_HOME" ] || [ "$HOST_HOME" = "/cache" ] || [ ! -d "$HOST_HOME" ]; then
    HOST_HOME="$PROJECT_ROOT"
  fi
}

resolve_effective_tools_list() {
  local inferred_tools=""

  resolve_tool_config_roots

  if [ -d "$CODEX_HOST_CONFIG" ] || [ "$CODEX_CONFIG_MODE" = "project" ] || [ "$CODEX_CONFIG_MODE" = "fresh" ] || [ -n "${CODEX_CONFIG:-}" ]; then
    inferred_tools="${inferred_tools:+$inferred_tools }codex"
  elif [ -n "${CODEX_AUTH:-}" ] || [ -d "${CODEX_AUTH_BASE:-}" ]; then
    inferred_tools="${inferred_tools:+$inferred_tools }codex"
  elif [ -n "${OPENAI_API_KEY:-}" ]; then
    inferred_tools="${inferred_tools:+$inferred_tools }codex"
  fi

  if [ -d "$CLAUDE_HOST_CONFIG" ] || [ "$CLAUDE_CONFIG_MODE" = "project" ] || [ "$CLAUDE_CONFIG_MODE" = "fresh" ] || [ -n "${CLAUDE_CONFIG:-}" ]; then
    inferred_tools="${inferred_tools:+$inferred_tools }claude"
  elif [ -n "${CLAUDE_AUTH:-}" ] || [ -d "${CLAUDE_AUTH_BASE:-}" ]; then
    inferred_tools="${inferred_tools:+$inferred_tools }claude"
  fi

  if [ -d "$OPENCODE_HOST_CONFIG" ] || [ "$OPENCODE_CONFIG_MODE" = "project" ] || [ "$OPENCODE_CONFIG_MODE" = "fresh" ] || [ -n "${OPENCODE_CONFIG:-}" ]; then
    inferred_tools="${inferred_tools:+$inferred_tools }opencode"
  elif [ -n "${OPENCODE_AUTH:-}" ] || [ -d "${OPENCODE_AUTH_BASE:-}" ]; then
    inferred_tools="${inferred_tools:+$inferred_tools }opencode"
  fi

  if [ -d "$OMP_HOST_CONFIG" ]; then
    inferred_tools="${inferred_tools:+$inferred_tools }omp"
  fi

  if [ -d "$COMMANDCODE_HOST_CONFIG" ] || [ "$COMMANDCODE_CONFIG_MODE" = "project" ] || [ "$COMMANDCODE_CONFIG_MODE" = "fresh" ] || [ -n "${COMMANDCODE_CONFIG:-}" ]; then
    inferred_tools="${inferred_tools:+$inferred_tools }commandcode"
  elif [ -n "${COMMANDCODE_AUTH:-}" ] || [ -d "${COMMANDCODE_AUTH_BASE:-}" ]; then
    inferred_tools="${inferred_tools:+$inferred_tools }commandcode"
  fi

  if [ -d "$CODEX_HOST_CONFIG" ] && [ -d "$CLAUDE_HOST_CONFIG" ] && [ -d "$OPENCODE_HOST_CONFIG" ]; then
    inferred_tools="${inferred_tools:+$inferred_tools }codemachine"
  fi

  EFFECTIVE_TOOLS_LIST="$KNOWN_TOOLS"
  if [ -n "$inferred_tools" ]; then
    EFFECTIVE_TOOLS_SOURCE="inferred"
  else
    EFFECTIVE_TOOLS_SOURCE="fallback-all"
  fi
}

prepare_tool_resolution_context() {
  resolve_project_paths
  load_project_config
  resolve_host_home
  prepare_cache_dirs
  resolve_effective_tools_list
}

prepare_project_contract_input() {
  TMP_DIR=""
  STORE_INPUT_PATH=""
  STORE_INPUT_NAME=""
  PROJECT_OVERRIDE_ARGS=()

  if [ -f "$PROJECT_NIX_DIR/packages.nix" ]; then
    TMP_DIR="$(mktemp -d)"
    stage_project_contract_input "$TMP_DIR"
    STORE_INPUT_PATH="$TMP_DIR"
    STORE_INPUT_NAME="project-nix"
  elif [ -f "$PROJECT_ROOT/shell.nix" ]; then
    TMP_DIR="$(mktemp -d)"
    stage_project_contract_input "$TMP_DIR"
    STORE_INPUT_PATH="$TMP_DIR"
    STORE_INPUT_NAME="project-shell"
  else
    STORE_INPUT_NAME="empty-project"
  fi
}

prepare_cache_dirs() {
  DEFAULT_CACHE_BASE="${XDG_CACHE_HOME:-$HOST_HOME/.cache}"
  if ! mkdir -p "$DEFAULT_CACHE_BASE" >/dev/null 2>&1; then
    DEFAULT_CACHE_BASE="$PROJECT_ROOT/.cache-agent"
  fi
  CACHE_DIR="${AGENT_CACHE_DIR:-$DEFAULT_CACHE_BASE/agent-sandbox}"
  GCROOTS_DIR="$CACHE_DIR/gcroots"
  IMAGES_DIR="$CACHE_DIR/images"
  HELPER_TMPDIR="${AGENT_HELPER_TMPDIR:-$CACHE_DIR/tmp}"
  mkdir -p "$CACHE_DIR" "$GCROOTS_DIR" "$IMAGES_DIR" "$HELPER_TMPDIR"
}

resolve_direnv_nix_path() {
  local expr=""
  local resolved_path=""

  AGENT_DIRENV_NIX_PATH="${AGENT_DIRENV_NIX_PATH:-}"

  if [ -n "$AGENT_DIRENV_NIX_PATH" ] && [ -e "$AGENT_DIRENV_NIX_PATH" ]; then
    export AGENT_DIRENV_NIX_PATH
    return 0
  fi

  AGENT_DIRENV_NIX_PATH=""

  if ! command -v nix >/dev/null 2>&1; then
    return 0
  fi

  expr="let flake = builtins.getFlake \"${SANDBOX_FLAKE}\"; in if flake.inputs ? nixpkgs then flake.inputs.nixpkgs.outPath else \"\""
  resolved_path="$(nix_cmd eval --impure --raw --expr "$expr" 2>/dev/null || true)"

  if [ -n "$resolved_path" ] && [ -e "$resolved_path" ]; then
    AGENT_DIRENV_NIX_PATH="$resolved_path"
    export AGENT_DIRENV_NIX_PATH
  fi
}

log_debug_context() {
  if [ "${AGENT_DEBUG:-0}" = "1" ]; then
    echo "[agent] TOOL=$TOOL" >&2
    echo "[agent] SANDBOX_PROFILE=${SANDBOX_PROFILE:-default}" >&2
    echo "[agent] RUNTIME=$RUNTIME" >&2
    echo "[agent] SANDBOX_FLAKE=$SANDBOX_FLAKE" >&2
    echo "[agent] PROJECT_ROOT=$PROJECT_ROOT" >&2
    echo "[agent] PROJECT_CONFIG_FILE=${PROJECT_CONFIG_FILE:-}" >&2
    echo "[agent] STORE_INPUT_PATH=$STORE_INPUT_PATH" >&2
    echo "[agent] DEV_ENV_MODE=${DEV_ENV_MODE:-unset}" >&2
    echo "[agent] DEV_ENV_ENV_FILE=${DEV_ENV_ENV_FILE:-}" >&2
    echo "[agent] DIRENV_NIX_PATH=${AGENT_DIRENV_NIX_PATH:-}" >&2
    echo "[agent] CONTAINER_API_MODE=${CONTAINER_API_MODE:-none}" >&2
    echo "[agent] NEED_HELPER_MODE=${NEED_HELPER_MODE:-0}" >&2
  fi
}

prepare_project_store_input() {
  PROJECT_STORE_PATH=""
  STORE_ADD_MS=0

  if [ -n "$STORE_INPUT_PATH" ]; then
    STORE_ADD_START_MS="$(now_ms)"
    if PROJECT_STORE_PATH="$(nix_cmd store add --mode nar --name "$STORE_INPUT_NAME" "$STORE_INPUT_PATH" 2>/dev/null)"; then
      :
    else
      PROJECT_STORE_PATH="$(nix_cmd store add-path "$STORE_INPUT_PATH" --name "$STORE_INPUT_NAME")"
    fi
    STORE_ADD_END_MS="$(now_ms)"
    STORE_ADD_MS="$((STORE_ADD_END_MS - STORE_ADD_START_MS))"
    PROJECT_OVERRIDE_ARGS=( --override-input projectPkgs "path:${PROJECT_STORE_PATH}" )
    perf_log "project store input (${STORE_INPUT_NAME}) resolved in $(format_duration_ms "$STORE_ADD_MS")"
  else
    perf_log "project store input (${STORE_INPUT_NAME}) resolved in 0ms"
  fi

  STORE_KEY="${PROJECT_STORE_PATH##*/}"
  if [ -z "$STORE_KEY" ]; then
    STORE_KEY="$STORE_INPUT_NAME"
  fi
}

bootstrap_environment() {
  OS_NAME="$(uname -s)"

  mkdir -p "${TMPDIR:-/tmp}" >/dev/null 2>&1 || true
  mkdir -p /var/tmp >/dev/null 2>&1 || true

  prepare_tool_resolution_context
  resolve_sandbox_profile
  resolve_runtime
  preflight_firecracker_host_profile
  preflight_rootless_linux_profile
  resolve_sandbox_flake
  resolve_lock_args
  prepare_project_contract_input
  resolve_direnv_nix_path
  prepare_dev_env_state
  prepare_project_store_input
}
