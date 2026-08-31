RUNTIME_LEASE_ID=""
RUNTIME_LEASE_DIR=""
RUNTIME_LEASE_ROOTS_DIR=""
RUNTIME_LEASE_RECEIPTS_DIR=""
RUNTIME_LEASE_PERSIST="0"

runtime_lease_dir_is_managed() {
  local lease_dir="$1"

  [ -n "${CACHE_DIR:-}" ] || return 1
  case "$lease_dir" in
    *$'\n'*|*/../*|*/..|*/./*|*/.) return 1 ;;
  esac
  case "$lease_dir" in
    "$CACHE_DIR/runtime-leases/"*)
      [ "$lease_dir" != "$CACHE_DIR/runtime-leases/" ]
      ;;
    "$CACHE_DIR/remote/"*/runtime-lease)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

runtime_lease_scope() {
  if [ "$RUNTIME_LEASE_PERSIST" = "1" ]; then
    printf 'remote-sandbox\n'
  else
    printf 'foreground-sandbox\n'
  fi
}

runtime_process_identity() {
  local pid="$1"
  local stat_line=""
  local stat_fields=""
  local field=""
  local index="0"
  local start_time=""
  local boot_id=""

  if [ -r "/proc/$pid/stat" ]; then
    stat_line="$(cat "/proc/$pid/stat" 2>/dev/null || true)"
    stat_fields="${stat_line##*) }"
    for field in $stat_fields; do
      index=$((index + 1))
      if [ "$index" -eq 20 ]; then
        start_time="$field"
        break
      fi
    done
    boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    if [ -n "$start_time" ]; then
      printf '%s:%s\n' "$boot_id" "$start_time"
      return 0
    fi
  fi

  ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

runtime_lease_owner_running() {
  local lease_dir="$1"
  local owner_file="$lease_dir/owner.env"
  local owner_pid=""
  local owner_identity=""
  local container_state=""
  local key=""
  local value=""

  if [ -f "$owner_file" ]; then
    while IFS='=' read -r key value; do
      case "$key" in
        pid) owner_pid="$value" ;;
        identity) owner_identity="$value" ;;
      esac
    done < "$owner_file"

    case "$owner_pid" in
      ''|*[!0-9]*) ;;
      *)
        if [ -n "$owner_identity" ] \
          && kill -0 "$owner_pid" 2>/dev/null \
          && [ "$(runtime_process_identity "$owner_pid")" = "$owner_identity" ]; then
          return 0
        fi
        ;;
    esac
  fi

  if runtime_lease_bound_container_exists "$lease_dir"; then
    return 0
  else
    container_state="$?"
  fi

  # An unavailable runtime cannot prove teardown. Retaining a stale bounded
  # lease is safer than collecting a possibly live sandbox's runtime.
  [ "$container_state" -eq 2 ]
}

runtime_lease_bound_container_exists() {
  local lease_dir="$1"
  local binding_file="$lease_dir/container.env"
  local runtime=""
  local profile=""
  local container_name=""
  local key=""
  local value=""
  local status=""

  [ -f "$binding_file" ] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      runtime) runtime="$value" ;;
      profile) profile="$value" ;;
      container) container_name="$value" ;;
    esac
  done < "$binding_file"

  [ "$runtime" = "podman" ] || return 1
  case "$profile" in
    default|rootless-linux|firecracker-host) ;;
    *) return 1 ;;
  esac
  case "$container_name" in
    agent-*) ;;
    *) return 1 ;;
  esac
  case "$container_name" in
    *[!A-Za-z0-9_.-]*) return 1 ;;
  esac

  if [ "$profile" = "firecracker-host" ]; then
    command -v sudo >/dev/null 2>&1 || return 2
    sudo -n podman --version >/dev/null 2>&1 || return 2
    if sudo -n podman container exists "$container_name" >/dev/null 2>&1; then
      return 0
    else
      status="$?"
    fi
  else
    command -v podman >/dev/null 2>&1 || return 2
    if env -u CONTAINER_HOST -u CONTAINER_CONNECTION -u DOCKER_HOST \
      podman container exists "$container_name" >/dev/null 2>&1; then
      return 0
    else
      status="$?"
    fi
  fi

  [ "$status" -eq 1 ] && return 1
  return 2
}

bind_runtime_lease_to_container() {
  local runtime="$1"
  local profile="$2"
  local container_name="$3"
  local pending=""

  [ -n "$RUNTIME_LEASE_DIR" ] || {
    echo "[agent] ERROR: cannot bind an unavailable runtime lease" >&2
    return 1
  }
  runtime_lease_dir_is_managed "$RUNTIME_LEASE_DIR" || {
    echo "[agent] ERROR: refusing unmanaged runtime lease path: $RUNTIME_LEASE_DIR" >&2
    return 1
  }
  [ "$runtime" = "podman" ] || {
    echo "[agent] ERROR: runtime lease container binding requires podman" >&2
    return 1
  }
  case "$profile" in
    default|rootless-linux|firecracker-host) ;;
    *)
      echo "[agent] ERROR: invalid runtime lease container profile: $profile" >&2
      return 1
      ;;
  esac
  case "$container_name" in
    agent-*) ;;
    *)
      echo "[agent] ERROR: invalid runtime lease container name: $container_name" >&2
      return 1
      ;;
  esac
  case "$container_name" in
    *[!A-Za-z0-9_.-]*)
      echo "[agent] ERROR: invalid runtime lease container name: $container_name" >&2
      return 1
      ;;
  esac

  pending="$(mktemp "$RUNTIME_LEASE_DIR/.container.env.XXXXXX")"
  {
    printf 'runtime=%s\n' "$runtime"
    printf 'profile=%s\n' "$profile"
    printf 'container=%s\n' "$container_name"
  } > "$pending"
  chmod 0600 "$pending"
  mv -f "$pending" "$RUNTIME_LEASE_DIR/container.env"
}

prepare_runtime_lease_guard() {
  local guard_pid=""
  local ready_attempt="0"

  [ -f "$RUNTIME_LEASE_DIR/container.env" ] || {
    echo "[agent] ERROR: runtime lease guard requires a bound container" >&2
    return 1
  }
  command -v nohup >/dev/null 2>&1 || {
    echo "[agent] ERROR: runtime lease guard requires nohup" >&2
    return 1
  }
  [ -x "$AGENT_BIN_DIR/agent-runtime-lease-guard" ] || {
    echo "[agent] ERROR: runtime lease guard is not executable" >&2
    return 1
  }

  (
    umask 077
    exec nohup "$AGENT_BIN_DIR/agent-runtime-lease-guard" \
      "$RUNTIME_LEASE_DIR" "$CACHE_DIR" \
      </dev/null >"$RUNTIME_LEASE_DIR/guard.log" 2>&1
  ) &
  guard_pid="$!"
  printf '%s\n' "$guard_pid" > "$RUNTIME_LEASE_DIR/guard.pid"

  while [ "$ready_attempt" -lt 20 ]; do
    if kill -0 "$guard_pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
    ready_attempt=$((ready_attempt + 1))
  done

  echo "[agent] ERROR: runtime lease guard failed to start" >&2
  if [ -s "$RUNTIME_LEASE_DIR/guard.log" ]; then
    sed 's/^/[agent] runtime lease guard: /' "$RUNTIME_LEASE_DIR/guard.log" >&2
  fi
  return 1
}

runtime_lease_helper_process_matches() {
  local pid="$1"
  local bridge_dir="$2"
  local command_line=""

  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1

  if [ -r "/proc/$pid/cmdline" ]; then
    command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  else
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  fi
  case "$command_line" in
    *agent-nix-helper*serve*"$bridge_dir"*) return 0 ;;
    *) return 1 ;;
  esac
}

prune_stale_runtime_leases() {
  local lease_dir=""

  mkdir -p "$CACHE_DIR/runtime-leases"
  for lease_dir in "$CACHE_DIR/runtime-leases"/sandbox-*; do
    [ -d "$lease_dir" ] || continue
    if ! runtime_lease_owner_running "$lease_dir"; then
      remove_runtime_lease "$lease_dir"
    fi
  done
}

write_runtime_lease_manifest() {
  local target="$RUNTIME_LEASE_RECEIPTS_DIR/lease.json"
  local pending=""

  pending="$(mktemp "$RUNTIME_LEASE_RECEIPTS_DIR/.lease.json.XXXXXX")"
  if ! jq -n \
    --arg lease_id "$RUNTIME_LEASE_ID" \
    --arg scope "$(runtime_lease_scope)" \
    '{
      schema_version: 1,
      lease_id: $lease_id,
      owner: "agent-sandbox",
      scope: $scope,
      retention: "until-sandbox-teardown",
      receipt_directory: "/run/agent-runtime-receipts"
    }' > "$pending"; then
    rm -f "$pending"
    echo "[agent] ERROR: could not write runtime lease manifest" >&2
    return 1
  fi

  chmod 0444 "$pending"
  mv -f "$pending" "$target"
}

prepare_runtime_lease() {
  local lease_nonce=""

  if [ "${AGENT_COMMAND:-run}" = "remote" ]; then
    if [ -z "${REMOTE_STATE_DIR:-}" ] || [ -z "${REMOTE_NAME:-}" ]; then
      echo "[agent] ERROR: remote runtime lease requires initialized remote state" >&2
      return 1
    fi
    RUNTIME_LEASE_ID="remote-$(hash_short "$REMOTE_NAME|$PROJECT_ROOT")"
    RUNTIME_LEASE_DIR="$REMOTE_STATE_DIR/runtime-lease"
    RUNTIME_LEASE_PERSIST="1"
    mkdir -p "$RUNTIME_LEASE_DIR"
  else
    prune_stale_runtime_leases
    lease_nonce="$(date +%s%N 2>/dev/null || date +%s)-$$-${RANDOM:-0}"
    RUNTIME_LEASE_ID="sandbox-$(hash_short "$PROJECT_ROOT|$lease_nonce")"
    RUNTIME_LEASE_DIR="$CACHE_DIR/runtime-leases/$RUNTIME_LEASE_ID"
    RUNTIME_LEASE_PERSIST="0"
    mkdir -p "$CACHE_DIR/runtime-leases"
    if ! mkdir "$RUNTIME_LEASE_DIR"; then
      echo "[agent] ERROR: could not create unique runtime lease: $RUNTIME_LEASE_DIR" >&2
      return 1
    fi
  fi

  runtime_lease_dir_is_managed "$RUNTIME_LEASE_DIR" || {
    echo "[agent] ERROR: refusing unmanaged runtime lease path: $RUNTIME_LEASE_DIR" >&2
    return 1
  }

  RUNTIME_LEASE_ROOTS_DIR="$RUNTIME_LEASE_DIR/roots"
  RUNTIME_LEASE_RECEIPTS_DIR="$RUNTIME_LEASE_DIR/receipts"
  mkdir -p "$RUNTIME_LEASE_ROOTS_DIR" "$RUNTIME_LEASE_RECEIPTS_DIR"
  chmod 0700 "$RUNTIME_LEASE_DIR" "$RUNTIME_LEASE_ROOTS_DIR"
  chmod 0755 "$RUNTIME_LEASE_RECEIPTS_DIR"
  {
    printf 'pid=%s\n' "$$"
    printf 'identity=%s\n' "$(runtime_process_identity "$$")"
  } > "$RUNTIME_LEASE_DIR/owner.env"
  chmod 0600 "$RUNTIME_LEASE_DIR/owner.env"
  write_runtime_lease_manifest
}

runtime_lease_path_info() {
  local target="$1"
  shift
  local nix_features="${AGENT_NIX_EXPERIMENTAL_FEATURES:-nix-command flakes}"

  if ! env -u NIX_CONFIG nix --extra-experimental-features "$nix_features" \
    path-info --json --recursive "$@" > "$target"; then
    echo "[agent] ERROR: could not inspect retained Nix closure" >&2
    return 1
  fi
}

write_runtime_artifact_receipt() {
  local artifact_kind="$1"
  local store_path="$2"
  local target="$RUNTIME_LEASE_RECEIPTS_DIR/runtime-$artifact_kind.json"
  local closure_file=""
  local pending=""

  closure_file="$(mktemp "$RUNTIME_LEASE_DIR/.closure.XXXXXX")"
  pending="$(mktemp "$RUNTIME_LEASE_RECEIPTS_DIR/.runtime-$artifact_kind.json.XXXXXX")"
  if ! runtime_lease_path_info "$closure_file" "$store_path"; then
    rm -f "$closure_file" "$pending"
    return 1
  fi

  if ! jq -n \
    --arg lease_id "$RUNTIME_LEASE_ID" \
    --arg artifact "$artifact_kind" \
    --arg store_path "$store_path" \
    --slurpfile closure "$closure_file" \
    '{
      schema_version: 1,
      lease_id: $lease_id,
      kind: "runtime-artifact",
      artifact: $artifact,
      output_paths: [$store_path],
      closure: ($closure[0] | to_entries | map({
        path: .key,
        narHash: .value.narHash,
        narSize: .value.narSize,
        references: (.value.references // [])
      }) | sort_by(.path))
    }' > "$pending"; then
    rm -f "$closure_file" "$pending"
    echo "[agent] ERROR: could not write runtime artifact receipt" >&2
    return 1
  fi

  rm -f "$closure_file"
  chmod 0444 "$pending"
  mv -f "$pending" "$target"
}

retain_runtime_artifact() {
  local artifact_kind="$1"
  local store_path="$2"
  local root_path="$RUNTIME_LEASE_ROOTS_DIR/runtime-$artifact_kind"

  register_host_gc_root "$store_path" "$root_path"
  if ! write_runtime_artifact_receipt "$artifact_kind" "$store_path"; then
    rm -f "$root_path"
    return 1
  fi
}

runtime_lease_has_artifact_receipt() {
  local receipt=""
  local receipt_data=""
  local artifact_kind=""
  local store_path=""

  for receipt in "$RUNTIME_LEASE_RECEIPTS_DIR"/runtime-*.json; do
    [ -f "$receipt" ] || continue
    receipt_data="$(
      jq -er \
        --arg lease_id "$RUNTIME_LEASE_ID" \
        'select(
          .schema_version == 1 and
          .kind == "runtime-artifact" and
          .lease_id == $lease_id and
          (.artifact | type) == "string" and
          (.output_paths | type) == "array" and
          (.output_paths | length) == 1 and
          (.output_paths[0] | type) == "string" and
          (.closure | type) == "array" and
          (.output_paths[0] as $output_path | .closure | any(.path == $output_path))
        ) | [.artifact, .output_paths[0]] | @tsv' \
        "$receipt" 2>/dev/null
    )" || continue
    IFS=$'\t' read -r artifact_kind store_path <<< "$receipt_data"
    case "$artifact_kind" in
      rootfs|stream-image) ;;
      *) continue ;;
    esac
    assert_host_gc_root "$store_path" "$RUNTIME_LEASE_ROOTS_DIR/runtime-$artifact_kind" || continue
    return 0
  done
  return 1
}

stop_runtime_lease_helper() {
  local lease_dir="$1"
  local pid_file="$lease_dir/need-helper/service.pid"
  local bridge_dir="$lease_dir/need-helper/bridge"
  local pid=""
  local waited="0"

  [ -f "$pid_file" ] || return 0
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  runtime_lease_helper_process_matches "$pid" "$bridge_dir" || return 0
  kill "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if runtime_lease_helper_process_matches "$pid" "$bridge_dir"; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

remove_runtime_lease() {
  local lease_dir="$1"

  [ -e "$lease_dir" ] || return 0
  runtime_lease_dir_is_managed "$lease_dir" || {
    echo "[agent] ERROR: refusing to remove unmanaged runtime lease: $lease_dir" >&2
    return 1
  }

  stop_runtime_lease_helper "$lease_dir"
  rm -rf -- "$lease_dir"
}

cleanup_runtime_lease() {
  local container_state=""

  [ -n "$RUNTIME_LEASE_DIR" ] || return 0
  [ "$RUNTIME_LEASE_PERSIST" = "0" ] || return 0

  if runtime_lease_bound_container_exists "$RUNTIME_LEASE_DIR"; then
    return 0
  else
    container_state="$?"
  fi
  if [ "$container_state" -eq 2 ]; then
    echo "[agent] warning: retaining runtime lease because container teardown could not be confirmed" >&2
    return 0
  fi

  remove_runtime_lease "$RUNTIME_LEASE_DIR"
}
