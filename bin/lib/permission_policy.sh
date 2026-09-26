# Shared by the host launcher and immutable in-container tool launchers.
# Inspect intent without changing argv or trying to evaluate upstream config.
inspect_tool_permission_args() {
  local tool="${1:-}" arg value key positional_seen=0
  [ "$#" -eq 0 ] || shift
  PERMISSION_HAS_BYPASS=0
  PERMISSION_HAS_CONTROLS=0
  PERMISSION_CONTAINER_CONFLICT=0
  PERMISSION_BYPASS_CONFLICT=0
  PERMISSION_WORKSPACE_WRITE=0
  PERMISSION_CWD="${AGENT_WORKSPACE_PATH:-$PWD}"
  while [ "$#" -gt 0 ]; do
    arg="$1"
    shift
    [ "$arg" != -- ] || break
    case "$tool:$arg" in
      codex:--yolo|codex:--dangerously-bypass-approvals-and-sandbox|claude:--dangerously-skip-permissions|antigravity:--dangerously-skip-permissions|omp:--yolo|omp:--auto-approve|commandcode:--yolo|commandcode:--dangerously-skip-permissions)
        PERMISSION_HAS_BYPASS=1; continue ;;
      codex:-C|codex:--cd)
        PERMISSION_CWD="${1:-$PERMISSION_CWD}"
        [ "$#" -eq 0 ] || shift
        continue ;;
      codex:--cd=*) PERMISSION_CWD="${arg#*=}"; continue ;;
      codex:-P|codex:--permission-profile|codex:--permissions-profile|codex:-p|codex:--profile)
        [ "$#" -eq 0 ] || shift
        PERMISSION_HAS_CONTROLS=1; PERMISSION_CONTAINER_CONFLICT=1; continue ;;
      codex:--permission-profile=*|codex:--permissions-profile=*|codex:--profile=*)
        PERMISSION_HAS_CONTROLS=1; PERMISSION_CONTAINER_CONFLICT=1; continue ;;
      claude:-p|claude:--print) continue ;;
      claude:--append-system-prompt|claude:--system-prompt|claude:--append-system-prompt-file|claude:--system-prompt-file)
        [ "$#" -eq 0 ] || shift
        continue ;;
      *:-m|*:--model|*:-p|*:--prompt|*:--print|*:-C|*:--cd|*:--output-format|*:--input-format)
        [ "$#" -eq 0 ] || shift
        continue ;;
      codex:-s|codex:--sandbox|codex:-a|codex:--ask-for-approval|claude:--permission-mode|commandcode:--permission-mode)
        value="${1:-}"
        [ "$#" -eq 0 ] || shift ;;
      codex:--sandbox=*|codex:--ask-for-approval=*|claude:--permission-mode=*|commandcode:--permission-mode=*)
        value="${arg#*=}" ;;
      codex:-c|codex:--config|codex:--config=*)
        if [[ "$arg" == --config=* ]]; then key="${arg#*=}"; else
          key="${1:-}"
          [ "$#" -eq 0 ] || shift
        fi
        key="${key%%=*}"
        key="${key//[[:space:]]/}"
        case "$key" in
          sandbox_mode|sandbox_workspace_write.*|approval_policy|approvals_reviewer|default_permissions|permissions.*)
            PERMISSION_HAS_CONTROLS=1; PERMISSION_CONTAINER_CONFLICT=1 ;;
        esac
        continue ;;
      claude:--settings)
        [ "$#" -eq 0 ] || shift
        PERMISSION_HAS_CONTROLS=1; PERMISSION_CONTAINER_CONFLICT=1; continue ;;
      claude:--settings=*)
        PERMISSION_HAS_CONTROLS=1; PERMISSION_CONTAINER_CONFLICT=1; continue ;;
      codex:sandbox)
        if [ "$positional_seen" = 0 ]; then
          PERMISSION_HAS_CONTROLS=1; PERMISSION_CONTAINER_CONFLICT=1; PERMISSION_BYPASS_CONFLICT=1
        fi
        positional_seen=1; continue ;;
      codex:--approve-for-me|codex:--not-so-yolo|codex:--full-auto|claude:--restricted|commandcode:--plan|commandcode:--accept-edits|antigravity:--sandbox|antigravity:--sandbox=*)
        PERMISSION_HAS_CONTROLS=1; PERMISSION_CONTAINER_CONFLICT=1
        PERMISSION_BYPASS_CONFLICT=1; continue ;;
      *) [[ "$arg" == -* ]] || positional_seen=1; continue ;;
    esac
    PERMISSION_HAS_CONTROLS=1
    case "$tool:$arg:$value" in
      claude:--permission-mode*:bypassPermissions|commandcode:--permission-mode*:yolo)
        PERMISSION_HAS_BYPASS=1 ;;
      codex:-s:danger-full-access|codex:--sandbox*:danger-full-access|codex:-a:never|codex:--ask-for-approval*:never) ;;
      *) PERMISSION_CONTAINER_CONFLICT=1; PERMISSION_BYPASS_CONFLICT=1 ;;
    esac
    case "$tool:$arg" in
      codex:-s|codex:--sandbox*)
        PERMISSION_WORKSPACE_WRITE=0
        [ "$value" != workspace-write ] || PERMISSION_WORKSPACE_WRITE=1 ;;
    esac
  done
  if [ "$tool" = opencode ] && [ -n "${OPENCODE_PERMISSION:-}" ]; then
    PERMISSION_HAS_CONTROLS=1
  fi
}

resolve_permission_policy() {
  inspect_tool_permission_args "$@"
  PERMISSION_POLICY="${AGENT_PERMISSION_POLICY:-}"
  PERMISSION_POLICY_SOURCE="process environment"
  if declare -p PROJECT_CONFIG_SOURCES >/dev/null 2>&1; then
    PERMISSION_POLICY_SOURCE="${PROJECT_CONFIG_SOURCES[AGENT_PERMISSION_POLICY]:-process environment}"
  fi
  if [ -z "$PERMISSION_POLICY" ]; then
    PERMISSION_POLICY_SOURCE="tool permission controls"
    if [ "$PERMISSION_HAS_BYPASS" = 1 ] && [ "$PERMISSION_CONTAINER_CONFLICT" = 0 ]; then
      PERMISSION_POLICY=container
      PERMISSION_POLICY_SOURCE="tool permission bypass"
    elif [ "$PERMISSION_HAS_CONTROLS" = 1 ]; then
      PERMISSION_POLICY=native
    else
      PERMISSION_POLICY_SOURCE="sandbox profile default"
      if [ "${SANDBOX_PROFILE:-${AGENT_SANDBOX_PROFILE:-default}}" = rootless-linux ]; then
        PERMISSION_POLICY=native
      else
        PERMISSION_POLICY=container
      fi
    fi
  fi
  case "$PERMISSION_POLICY" in
    container|native) ;;
    *) echo '[agent] ERROR: AGENT_PERMISSION_POLICY must be container or native' >&2; return 1 ;;
  esac
}

permission_policy_conflict() {
  echo "[agent] ERROR: $1 conflicts with container permission policy; remove the explicit AGENT_PERMISSION_POLICY=container override or select native to preserve tool controls (an existing container must be relaunched)" >&2
  return 1
}

codex_protected_symlink() {
  local root="${1:-${AGENT_PERMISSION_PROJECT_ROOT:-${PROJECT_ROOT:-$PWD}}}" name
  for name in .codex .agents .git; do
    if [ -L "$root/$name" ]; then
      printf '%s\n' "$root/$name"
      return 0
    fi
  done
  return 1
}

validate_tool_permission_args() {
  local tool="$1" protected
  inspect_tool_permission_args "$@"
  if [ "$tool" = codemachine ] && [ "$PERMISSION_POLICY" = native ]; then
    echo '[agent] ERROR: CodeMachine hardcodes child permission bypasses; native permission policy is unsupported' >&2
    return 1
  fi
  if [ "$PERMISSION_HAS_BYPASS" = 1 ] && [ "$PERMISSION_BYPASS_CONFLICT" = 1 ]; then
    echo "[agent] ERROR: $tool permission bypass and restrictive permission controls cannot be combined" >&2
    return 1
  fi
  if [ "$PERMISSION_POLICY" = container ] && [ "$PERMISSION_CONTAINER_CONFLICT" = 1 ]; then
    permission_policy_conflict "$tool permission option" || return 1
  fi
  if [ "$PERMISSION_WORKSPACE_WRITE" = 1 ] && [ -d "$PERMISSION_CWD" ]; then
    PERMISSION_CWD="$(CDPATH= cd -- "$PERMISSION_CWD" && pwd -P)" || return 1
    if protected="$(codex_protected_symlink "$PERMISSION_CWD")"; then
      echo "[agent] ERROR: Codex workspace-write cannot protect writable symlink $protected; use a real metadata directory or replace workspace-write with --yolo to rely on the outer container" >&2
      return 1
    fi
  fi
}

apply_tool_permission_policy() {
  local tool="$1"
  shift
  resolve_permission_policy "$tool" "$@" || return 1
  validate_tool_permission_args "$tool" "$@" || return 1
  PERMISSION_TOOL_ARGS=("$@")
  [ "$PERMISSION_POLICY" = container ] || return 0
  local bypass=""
  case "$tool" in codex|omp|commandcode) bypass=--yolo ;; claude|antigravity) bypass=--dangerously-skip-permissions ;; esac
  case "$tool" in
    codex|omp|commandcode|antigravity) [ "$PERMISSION_HAS_BYPASS" = 1 ] || PERMISSION_TOOL_ARGS=("$bypass" "$@") ;;
    claude)
      PERMISSION_TOOL_ARGS=(--settings '{"sandbox":{"enabled":false}}' "$@")
      [ "$PERMISSION_HAS_BYPASS" = 1 ] || PERMISSION_TOOL_ARGS=("$bypass" "${PERMISSION_TOOL_ARGS[@]}")
      ;;
    opencode)
      if [ -n "${OPENCODE_PERMISSION:-}" ]; then
        if ! printf '%s' "$OPENCODE_PERMISSION" | jq -e '(. == "allow") or (type == "object" and .["*"] == "allow" and all(.[]; . == "allow"))' >/dev/null 2>&1; then
          permission_policy_conflict OPENCODE_PERMISSION || return 1
        fi
      fi
      export OPENCODE_PERMISSION='{"*":"allow"}'
      ;;
    codemachine) ;; # Child tool launchers inherit the resolved session policy.
    *) echo "[agent] ERROR: no permission adapter for tool '$tool'" >&2; return 1 ;;
  esac
}
