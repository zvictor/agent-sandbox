compute_sandbox_meta_key() {
  local meta_key="$SANDBOX_FLAKE"
  local file=""
  local rel_path=""

  case "$SANDBOX_FLAKE" in
    path:*)
      SANDBOX_PATH="${SANDBOX_FLAKE#path:}"
      if [ -d "$SANDBOX_PATH" ]; then
        meta_key="$(
          {
            printf '%s\n' "$SANDBOX_FLAKE"
            for f in flake.nix flake.lock; do
              if [ -f "$SANDBOX_PATH/$f" ]; then
                printf '>>> %s\n' "$f"
                cat "$SANDBOX_PATH/$f"
              fi
            done
            for dir in bin nix scripts; do
              if [ -d "$SANDBOX_PATH/$dir" ]; then
                while IFS= read -r file; do
                  rel_path="${file#"$SANDBOX_PATH/"}"
                  printf '>>> %s\n' "$rel_path"
                  cat "$file"
                done < <(find "$SANDBOX_PATH/$dir" -type f | LC_ALL=C sort)
              fi
            done
          } | sha256sum | awk '{print $1}'
        )"
      fi
      ;;
    *)
      if SANDBOX_META_JSON="$(nix_cmd flake metadata "$SANDBOX_FLAKE" --json "${LOCK_ARGS[@]}" 2>/dev/null)"; then
        meta_key="$(printf '%s\n' "$SANDBOX_META_JSON" | jq -r '.locked.narHash // .locked.rev // .narHash // .revision // .path // .resolvedUrl // .url // empty')"
        if [ -z "$meta_key" ] || [ "$meta_key" = "null" ]; then
          meta_key="$SANDBOX_FLAKE"
        fi
      fi
      ;;
  esac

  printf '%s\n' "$meta_key"
}

persist_artifact_gcroot() {
  local artifact_out="$1"
  local gcroot_path="$2"
  local tmp_root="${gcroot_path}.tmp.$$"

  if command -v nix-store >/dev/null 2>&1; then
    nix-store --add-root "$tmp_root" --indirect "$artifact_out" >/dev/null 2>&1 || ln -sfn "$artifact_out" "$tmp_root"
  else
    ln -sfn "$artifact_out" "$tmp_root"
  fi
  mv -f "$tmp_root" "$gcroot_path"
}

resolve_runtime_mode() {
  if [ "$RUNTIME" = "podman" ]; then
    MODE="podman-rootfs"
    if [ "$OS_NAME" != "Linux" ] || [ ! -d "/nix/store" ] || [ -n "${CONTAINER_HOST:-}" ]; then
      echo "[agent] podman mode requires local Linux with /nix/store and no CONTAINER_HOST." >&2
      exit 1
    fi
  else
    MODE="docker-oci"
  fi
}

init_artifact_paths() {
  IMAGE_GCROOT="$GCROOTS_DIR/${SANDBOX_KEY}--${STORE_KEY}--streamImage"
  IMAGE_ID_FILE="$IMAGES_DIR/${RUNTIME}-${SANDBOX_KEY}-${STORE_KEY}-streamImage.image-id"
  ROOTFS_GCROOT="$GCROOTS_DIR/${SANDBOX_KEY}--${STORE_KEY}--rootfs"
}

clear_artifact_caches_if_forced() {
  if [ "${AGENT_FORCE_REBUILD:-0}" = "1" ]; then
    rm -f "$IMAGE_GCROOT" "$IMAGE_ID_FILE" "$ROOTFS_GCROOT"
  fi
}

reset_artifact_state() {
  IMAGE_OUT=""
  BUILD_MS=0
  IMAGE_ID=""
  ROOTFS_OUT=""
  ROOTFS_IMAGE_ARG=""
  ROOTFS_RUN_MODE=""
  LOAD_MS=0
}

restore_cached_artifact_out() {
  local gcroot_path="$1"
  local cache_hit_message="$2"

  if [ -L "$gcroot_path" ] && [ -e "$gcroot_path" ]; then
    readlink -f "$gcroot_path"
    perf_log "$cache_hit_message"
  fi
}

build_cached_artifact() {
  local target_name="$1"
  local gcroot_path="$2"
  local build_label="$3"
  local cache_hit_message="$4"
  local success_perf_message="$5"
  local failure_message="$6"
  local artifact_out=""

  artifact_out="$(restore_cached_artifact_out "$gcroot_path" "$cache_hit_message")"

  if [ -z "$artifact_out" ] || [ ! -e "$artifact_out" ]; then
    echo "[agent] building ${build_label} (first run or package graph changed)..." >&2
    BUILD_START_MS="$(now_ms)"
    if ! artifact_out="$(
      nix_cmd build "${SANDBOX_FLAKE}#${target_name}" \
        "${PROJECT_OVERRIDE_ARGS[@]}" \
        --print-out-paths \
        --no-link \
        "${LOCK_ARGS[@]}"
    )"; then
      echo "$failure_message" >&2
      exit 1
    fi

    BUILD_END_MS="$(now_ms)"
    BUILD_MS="$((BUILD_END_MS - BUILD_START_MS))"
    echo "[agent] ${build_label} build completed in $(format_duration_ms "$BUILD_MS")" >&2
    perf_log "${success_perf_message} completed in $(format_duration_ms "$BUILD_MS")"

    persist_artifact_gcroot "$artifact_out" "$gcroot_path"
  fi

  printf '%s\n' "$artifact_out"
}

prepare_rootfs_artifact() {
  ROOTFS_OUT="$(
    build_cached_artifact \
      "rootfs" \
      "$ROOTFS_GCROOT" \
      "rootfs" \
      "rootfs derivation cache hit" \
      "nix build rootfs" \
      "[agent] rootfs build failed for podman mode."
  )"

  ROOTFS_RUN_MODE="$(detect_podman_rootfs_mode)"
  case "$ROOTFS_RUN_MODE" in
    overlay)
      ROOTFS_IMAGE_ARG="${ROOTFS_OUT}:O"
      ;;
    mirror)
      ROOTFS_IMAGE_ARG="$(prepare_writable_rootfs_mirror "$ROOTFS_OUT" "${SANDBOX_KEY}--${STORE_KEY}"):O"
      perf_log "using cached local rootfs mirror"
      ;;
  esac
}

prepare_stream_image_artifact() {
  IMAGE_OUT="$(
    build_cached_artifact \
      "streamImage" \
      "$IMAGE_GCROOT" \
      "streamImage" \
      "image derivation cache hit for streamImage" \
      "nix build streamImage" \
      "[agent] streamImage build failed for docker mode."
  )"
}

load_runtime_image_id() {
  local load_status=0
  local load_output=""
  local load_method="nix run streamImage.copyToDockerDaemon"
  local loaded_ref=""

  if [ -f "$IMAGE_ID_FILE" ]; then
    IMAGE_ID="$(cat "$IMAGE_ID_FILE")"
    if [ -n "$IMAGE_ID" ] && ! "$RUNTIME" image inspect "$IMAGE_ID" >/dev/null 2>&1; then
      IMAGE_ID=""
    elif [ -n "$IMAGE_ID" ]; then
      perf_log "runtime image id cache hit"
    fi
  fi

  if [ -n "$IMAGE_ID" ]; then
    return
  fi

  echo "[agent] loading image into $RUNTIME..." >&2
  LOAD_START_MS="$(now_ms)"
  HELPER_RESOLVE_START_MS="$(now_ms)"
  if load_output="$(run_stream_image_helper "copyToDockerDaemon" 2>&1)"; then
    load_status=0
  else
    load_status=$?
  fi
  HELPER_RESOLVE_END_MS="$(now_ms)"
  perf_log "copyToDockerDaemon helper completed in $(format_duration_ms "$((HELPER_RESOLVE_END_MS - HELPER_RESOLVE_START_MS))")"

  if [ "$load_status" -ne 0 ]; then
    echo "$load_output" >&2
    echo "[agent] image load failed with runtime '$RUNTIME' (status=$load_status)" >&2
    exit "$load_status"
  fi

  LOAD_END_MS="$(now_ms)"
  LOAD_MS="$((LOAD_END_MS - LOAD_START_MS))"
  perf_log "image load via ${load_method} completed in $(format_duration_ms "$LOAD_MS")"
  echo "$load_output" >&2

  IMAGE_ID="$($RUNTIME image inspect agent-base:latest --format '{{.Id}}' 2>/dev/null || true)"
  loaded_ref="$(printf '%s\n' "$load_output" | sed -n 's/^Loaded image(s):[[:space:]]*//p; s/^Loaded image:[[:space:]]*//p' | tail -n1 | tr -d '\r')"

  if [ -z "$IMAGE_ID" ] && [ -n "$loaded_ref" ]; then
    IMAGE_ID="$($RUNTIME image inspect "$loaded_ref" --format '{{.Id}}' 2>/dev/null || true)"
  fi

  if [ -z "$IMAGE_ID" ]; then
    IMAGE_ID="$(printf '%s\n' "$load_output" | sed -n 's/.*\(sha256:[0-9a-f]\{64\}\).*/\1/p' | head -n1)"
  fi

  if [ -z "$IMAGE_ID" ]; then
    IMAGE_ID="$($RUNTIME image inspect agent-base:latest --format '{{.Id}}' 2>/dev/null || true)"
  fi

  if [ -z "$IMAGE_ID" ]; then
    echo "[agent] failed to resolve image id after load" >&2
    exit 1
  fi

  printf '%s\n' "$IMAGE_ID" > "$IMAGE_ID_FILE"
}

log_prep_totals() {
  PREP_END_MS="$(now_ms)"
  PREP_TOTAL_MS="$((PREP_END_MS - RUN_START_MS))"
  if [ "$MODE" = "podman-rootfs" ]; then
    perf_log "prep total: $(format_duration_ms "$PREP_TOTAL_MS") (store=$(format_duration_ms "$STORE_ADD_MS"), build=$(format_duration_ms "$BUILD_MS"), mode=podman-rootfs)"
  else
    perf_log "prep total: $(format_duration_ms "$PREP_TOTAL_MS") (store=$(format_duration_ms "$STORE_ADD_MS"), build=$(format_duration_ms "$BUILD_MS"), load=$(format_duration_ms "$LOAD_MS"), mode=docker-oci)"
  fi
}

prepare_runtime_artifacts() {
  SANDBOX_META_KEY="$(compute_sandbox_meta_key)"
  SANDBOX_KEY="$(hash_short "$SANDBOX_META_KEY")"
  resolve_runtime_mode
  init_artifact_paths
  clear_artifact_caches_if_forced
  reset_artifact_state

  if [ "$MODE" = "podman-rootfs" ]; then
    prepare_rootfs_artifact
  else
    prepare_stream_image_artifact
    load_runtime_image_id
  fi

  log_prep_totals
}
