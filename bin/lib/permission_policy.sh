# Shared by the host launcher and immutable in-container tool launchers.
resolve_permission_policy() {
  PERMISSION_POLICY="${AGENT_PERMISSION_POLICY:-}"
  PERMISSION_POLICY_SOURCE="process environment"
  if declare -p PROJECT_CONFIG_SOURCES >/dev/null 2>&1; then
    PERMISSION_POLICY_SOURCE="${PROJECT_CONFIG_SOURCES[AGENT_PERMISSION_POLICY]:-process environment}"
  fi
  if [ -z "$PERMISSION_POLICY" ]; then
    PERMISSION_POLICY_SOURCE="sandbox profile default"
    if [ "${SANDBOX_PROFILE:-${AGENT_SANDBOX_PROFILE:-default}}" = rootless-linux ]; then
      PERMISSION_POLICY=native
    else
      PERMISSION_POLICY=container
    fi
  fi
  case "$PERMISSION_POLICY" in
    container|native) ;;
    *) echo '[agent] ERROR: AGENT_PERMISSION_POLICY must be container or native' >&2; return 1 ;;
  esac
}

permission_policy_conflict() {
  echo "[agent] ERROR: $1 conflicts with container permission policy; set AGENT_PERMISSION_POLICY=native to use tool permission controls" >&2
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
  local tool="$1" arg value key protected permission_cwd="${AGENT_WORKSPACE_PATH:-$PWD}" workspace_write=0
  shift
  if [ "$tool" = codemachine ] && [ "$PERMISSION_POLICY" = native ]; then
    echo '[agent] ERROR: CodeMachine hardcodes child permission bypasses; native permission policy is unsupported' >&2
    return 1
  fi
  while [ "$#" -gt 0 ]; do
    arg="$1"
    shift
    [ "$arg" != -- ] || break
    case "$tool:$arg" in
      codex:-C|codex:--cd)
        permission_cwd="${1:-$permission_cwd}"
        [ "$#" -eq 0 ] || shift
        continue
        ;;
      codex:--cd=*) permission_cwd="${arg#*=}"; continue ;;
      *:-m|*:--model|*:-p|*:--prompt|*:--print|*:-C|*:--cd|*:--output-format|*:--input-format)
        [ "$#" -eq 0 ] || shift
        continue
        ;;
      codex:-s|codex:--sandbox|codex:-a|codex:--ask-for-approval|claude:--permission-mode|commandcode:--permission-mode)
        value="${1:-}"
        [ "$#" -eq 0 ] || shift
        ;;
      codex:--sandbox=*|codex:--ask-for-approval=*|claude:--permission-mode=*|commandcode:--permission-mode=*)
        value="${arg#*=}"
        ;;
      codex:-c|codex:--config)
        key="${1:-}"
        [ "$#" -eq 0 ] || shift
        if [ "$PERMISSION_POLICY" = container ]; then
          case "$key" in sandbox_mode=*|approval_policy=*|approvals_reviewer=*|default_permissions=*|permissions.*=*) permission_policy_conflict 'Codex permission override' || return 1 ;; esac
        fi
        continue
        ;;
      codex:--config=*)
        key="${arg#*=}"
        if [ "$PERMISSION_POLICY" = container ]; then
          case "$key" in sandbox_mode=*|approval_policy=*|approvals_reviewer=*|default_permissions=*|permissions.*=*) permission_policy_conflict 'Codex permission override' || return 1 ;; esac
        fi
        continue
        ;;
      codex:--approve-for-me|codex:--full-auto|codex:sandbox|claude:--restricted|claude:--settings|claude:--settings=*|commandcode:--plan|commandcode:--accept-edits|antigravity:--sandbox|antigravity:--sandbox=*)
        [ "$PERMISSION_POLICY" != container ] || { permission_policy_conflict "$tool permission option"; return 1; }
        continue
        ;;
      *) continue ;;
    esac
    if [ "$PERMISSION_POLICY" = container ]; then
      case "$tool:$arg:$value" in
        codex:-s:danger-full-access|codex:--sandbox*:danger-full-access|codex:-a:never|codex:--ask-for-approval*:never|claude:--permission-mode*:bypassPermissions|commandcode:--permission-mode*:yolo) ;;
        *) permission_policy_conflict "$tool permission option" || return 1 ;;
      esac
    elif [ "$tool" = codex ] && [ "$value" = workspace-write ]; then
      workspace_write=1
    fi
  done
  if [ "$workspace_write" = 1 ] && [ -d "$permission_cwd" ]; then
    permission_cwd="$(CDPATH= cd -- "$permission_cwd" && pwd -P)" || return 1
    if protected="$(codex_protected_symlink "$permission_cwd")"; then
      echo "[agent] ERROR: Codex workspace-write cannot protect writable symlink $protected; use a real metadata directory or AGENT_PERMISSION_POLICY=container" >&2
      return 1
    fi
  fi
}

apply_tool_permission_policy() {
  local tool="$1"
  shift
  resolve_permission_policy || return 1
  validate_tool_permission_args "$tool" "$@" || return 1
  PERMISSION_TOOL_ARGS=("$@")
  [ "$PERMISSION_POLICY" = container ] || return 0
  # Upstream composites may already supply the bypass flag.
  local existing="" bypass="" arg
  case "$tool" in codex|omp|commandcode) bypass=--yolo ;; claude|antigravity) bypass=--dangerously-skip-permissions ;; esac
  for arg in "$@"; do
    if [ "$arg" = "$bypass" ] || { [ "$tool" = codex ] && [ "$arg" = --dangerously-bypass-approvals-and-sandbox ]; }; then existing=1; fi
  done
  case "$tool" in
    codex|omp|commandcode|antigravity) [ -n "$existing" ] || PERMISSION_TOOL_ARGS=("$bypass" "$@") ;;
    claude)
      PERMISSION_TOOL_ARGS=(--settings '{"sandbox":{"enabled":false}}' "$@")
      [ -n "$existing" ] || PERMISSION_TOOL_ARGS=("$bypass" "${PERMISSION_TOOL_ARGS[@]}")
      ;;
    opencode)
      if [ -n "${OPENCODE_PERMISSION:-}" ]; then
        if ! printf '%s' "$OPENCODE_PERMISSION" | jq -e '(. == "allow") or (type == "object" and .["*"] == "allow" and all(.[]; . == "allow"))' >/dev/null 2>&1; then
          permission_policy_conflict OPENCODE_PERMISSION || return 1
        fi
      fi
      export OPENCODE_PERMISSION='{"*":"allow"}'
      ;;
    codemachine) ;; # Child tool launchers inherit the policy environment.
    *) echo "[agent] ERROR: no permission adapter for tool '$tool'" >&2; return 1 ;;
  esac
}
