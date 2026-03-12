DIR_ENV_IGNORED_KEYS=$'DIRENV_DIFF\nDIRENV_DIR\nDIRENV_FILE\nDIRENV_WATCHES\nDIRENV_LAYOUT\nPWD\nOLDPWD\nSHLVL\n_\nHOME\nXDG_CACHE_HOME\nXDG_CONFIG_HOME\nXDG_DATA_HOME\nTMPDIR\nTOOL_CACHE\nCODEX_CACHE\nWORKSPACE_HOST_PATH\nNIX_CONFIG\nNIX_PATH\nshellHook\nbuildPhase\nphases'

should_ignore_dev_env_key() {
  local key="$1"

  case "$key" in
    DIRENV_*|deps*|buildInputs|nativeBuildInputs|propagatedBuildInputs|propagatedNativeBuildInputs|patches|builder|stdenv|outputs|out|name|system|shell|SHELL|HOST_PATH|CONFIG_SHELL|IN_NIX_SHELL|NIX_BUILD_CORES|NIX_ENFORCE_NO_NATIVE|NIX_BINTOOLS|NIX_BINTOOLS_WRAPPER_*|NIX_CC|NIX_CC_WRAPPER_*|SOURCE_DATE_EPOCH|preferLocalBuild|strictDeps|dontAddDisableDepTrack|doCheck|doInstallCheck|__structuredAttrs|cmakeFlags|mesonFlags|configureFlags|AS|CC|CXX|LD|AR|NM|OBJCOPY|OBJDUMP|RANLIB|READELF|STRIP|STRINGS|SIZE|size)
      return 0
      ;;
  esac

  while IFS= read -r ignored; do
    [ -z "$ignored" ] && continue
    if [ "$key" = "$ignored" ]; then
      return 0
    fi
  done < <(printf '%s\n' "$DIR_ENV_IGNORED_KEYS")

  return 1
}

write_dev_env_file_from_snapshot() {
  local snapshot_file="$1"
  local env_file="$2"
  local key=""
  local value=""
  local entry=""

  : > "$env_file"

  while IFS= read -r -d '' entry; do
    key="${entry%%=*}"
    value="${entry#*=}"

    case "$key" in
      ""|"PWD"|"OLDPWD")
        continue
        ;;
    esac

    if ! printf '%s' "$key" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then
      continue
    fi

    if should_ignore_dev_env_key "$key"; then
      continue
    fi

    case "$value" in
      *$'\n'*|*$'\r'*)
        echo "[agent] warning: skipping multiline direnv variable '$key'" >&2
        continue
        ;;
    esac

    printf '%s=%s\n' "$key" "$value" >> "$env_file"
  done < "$snapshot_file"
}

dev_env_file_has_entries() {
  local env_file="$1"

  [ -s "$env_file" ]
}

compute_dev_env_cache_key() {
  local tracked_file=""

  {
    printf 'mode=%s\n' "$DEV_ENV_MODE"
    printf 'workspace=%s\n' "$PROJECT_ROOT"
    printf 'nixpath=%s\n' "${AGENT_DIRENV_NIX_PATH:-}"
    printf 'helper-version=5\n'

    for tracked_file in \
      "$AGENT_BIN_DIR/agent-direnv-helper" \
      "$AGENT_BIN_DIR/lib/dev_env.sh"
    do
      [ -f "$tracked_file" ] || continue
      printf 'self %s\n' "$tracked_file"
      sha256sum "$tracked_file"
    done

    find "$PROJECT_ROOT" -maxdepth 1 -type f \( \
      -name '.envrc' -o \
      -name '.env*' -o \
      -name 'shell.nix' -o \
      -name 'flake.nix' -o \
      -name 'flake.lock' \
    \) -print | LC_ALL=C sort | while IFS= read -r tracked_file; do
      printf 'src %s\n' "${tracked_file#$PROJECT_ROOT/}"
      sha256sum "$tracked_file"
    done
  } | sha256sum | awk '{print $1}'
}

restore_dev_env_cache() {
  local cache_file="$1"
  local env_file="$2"

  if [ -f "$cache_file" ]; then
    cp "$cache_file" "$env_file"
    return 0
  fi

  return 1
}

store_dev_env_cache() {
  local env_file="$1"
  local cache_file="$2"

  mkdir -p "$(dirname "$cache_file")"
  cp "$env_file" "$cache_file"
}

prepare_dev_env_state() {
  DEV_ENV_MODE="${AGENT_DEV_ENV:-host-helper}"
  DEV_ENV_ENV_FILE=""

  case "$DEV_ENV_MODE" in
    none)
      perf_log "dev env helper disabled"
      return 0
      ;;
    host-helper)
      ;;
    *)
      echo "[agent] invalid AGENT_DEV_ENV='$DEV_ENV_MODE' (expected: none, host-helper)" >&2
      exit 1
      ;;
  esac

  if [ ! -f "$PROJECT_ROOT/.envrc" ]; then
    perf_log "dev env helper skipped (no .envrc)"
    return 0
  fi

  HELPER_STATE_DIR="$(mktemp -d "$HELPER_TMPDIR/dev-env.XXXXXX")"
  DEV_ENV_SNAPSHOT_FILE="$HELPER_STATE_DIR/direnv-snapshot.env0"
  DEV_ENV_ENV_FILE="$HELPER_STATE_DIR/direnv-export.env"
  DEV_ENV_CACHE_DIR="$CACHE_DIR/dev-env"
  DEV_ENV_CACHE_KEY="$(compute_dev_env_cache_key)"
  DEV_ENV_CACHE_FILE="$DEV_ENV_CACHE_DIR/$DEV_ENV_CACHE_KEY.env"

  if restore_dev_env_cache "$DEV_ENV_CACHE_FILE" "$DEV_ENV_ENV_FILE" && dev_env_file_has_entries "$DEV_ENV_ENV_FILE"; then
    perf_log "dev env helper snapshot cache hit"
    return 0
  fi

  if "$AGENT_BIN_DIR/agent-direnv-helper" snapshot-env "$PROJECT_ROOT" >"$DEV_ENV_SNAPSHOT_FILE" 2>"$HELPER_STATE_DIR/direnv-export.stderr"; then
    write_dev_env_file_from_snapshot "$DEV_ENV_SNAPSHOT_FILE" "$DEV_ENV_ENV_FILE"
    if dev_env_file_has_entries "$DEV_ENV_ENV_FILE"; then
      store_dev_env_cache "$DEV_ENV_ENV_FILE" "$DEV_ENV_CACHE_FILE"
      perf_log "dev env helper resolved host direnv snapshot"
    else
      DEV_ENV_ENV_FILE=""
      echo "[agent] warning: host direnv snapshot produced no startup environment variables for $PROJECT_ROOT" >&2
      if [ -s "$HELPER_STATE_DIR/direnv-export.stderr" ]; then
        sed 's/^/[agent] direnv: /' "$HELPER_STATE_DIR/direnv-export.stderr" >&2 || true
      fi
    fi
    return 0
  fi

  DEV_ENV_ENV_FILE=""
  echo "[agent] warning: host direnv snapshot failed for $PROJECT_ROOT" >&2
  sed 's/^/[agent] direnv: /' "$HELPER_STATE_DIR/direnv-export.stderr" >&2 || true
}
