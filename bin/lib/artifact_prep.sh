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

prepare_rootfs_artifact() {
  if [ -L "$ROOTFS_GCROOT" ] && [ -e "$ROOTFS_GCROOT" ]; then
    ROOTFS_OUT="$(readlink -f "$ROOTFS_GCROOT")"
    perf_log "rootfs derivation cache hit"
  fi

  if [ -z "$ROOTFS_OUT" ] || [ ! -e "$ROOTFS_OUT" ]; then
    echo "[agent] building rootfs (first run or package graph changed)..." >&2
    BUILD_START_MS="$(now_ms)"
    if ! ROOTFS_OUT="$(
      nix_cmd build "${SANDBOX_FLAKE}#rootfs" \
        "${PROJECT_OVERRIDE_ARGS[@]}" \
        --print-out-paths \
        --no-link \
        "${LOCK_ARGS[@]}"
    )"; then
      echo "[agent] rootfs build failed for podman mode." >&2
      exit 1
    fi

    BUILD_END_MS="$(now_ms)"
    BUILD_MS="$((BUILD_END_MS - BUILD_START_MS))"
    echo "[agent] rootfs build completed in $(format_duration_ms "$BUILD_MS")" >&2
    perf_log "nix build rootfs completed in $(format_duration_ms "$BUILD_MS")"

    persist_artifact_gcroot "$ROOTFS_OUT" "$ROOTFS_GCROOT"
  fi

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
  if [ -L "$IMAGE_GCROOT" ] && [ -e "$IMAGE_GCROOT" ]; then
    IMAGE_OUT="$(readlink -f "$IMAGE_GCROOT")"
    perf_log "image derivation cache hit for streamImage"
  fi

  if [ -z "$IMAGE_OUT" ] || [ ! -e "$IMAGE_OUT" ]; then
    echo "[agent] building streamImage (first run or package graph changed)..." >&2
    BUILD_START_MS="$(now_ms)"

    IMAGE_OUT="$(
      nix_cmd build "${SANDBOX_FLAKE}#streamImage" \
        "${PROJECT_OVERRIDE_ARGS[@]}" \
        --print-out-paths \
        --no-link \
        "${LOCK_ARGS[@]}"
    )"

    BUILD_END_MS="$(now_ms)"
    BUILD_MS="$((BUILD_END_MS - BUILD_START_MS))"
    echo "[agent] image build completed in $(format_duration_ms "$BUILD_MS")" >&2
    perf_log "nix build streamImage completed in $(format_duration_ms "$BUILD_MS")"

    persist_artifact_gcroot "$IMAGE_OUT" "$IMAGE_GCROOT"
  fi
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

prepare_runtime_artifacts() {
  SANDBOX_META_KEY="$(compute_sandbox_meta_key)"
  SANDBOX_KEY="$(hash_short "$SANDBOX_META_KEY")"

  if [ "$RUNTIME" = "podman" ]; then
    MODE="podman-rootfs"
    if [ "$OS_NAME" != "Linux" ] || [ ! -d "/nix/store" ] || [ -n "${CONTAINER_HOST:-}" ]; then
      echo "[agent] podman mode requires local Linux with /nix/store and no CONTAINER_HOST." >&2
      exit 1
    fi
  else
    MODE="docker-oci"
  fi

  IMAGE_GCROOT="$GCROOTS_DIR/${SANDBOX_KEY}--${STORE_KEY}--streamImage"
  IMAGE_ID_FILE="$IMAGES_DIR/${RUNTIME}-${SANDBOX_KEY}-${STORE_KEY}-streamImage.image-id"
  ROOTFS_GCROOT="$GCROOTS_DIR/${SANDBOX_KEY}--${STORE_KEY}--rootfs"

  if [ "${AGENT_FORCE_REBUILD:-0}" = "1" ]; then
    rm -f "$IMAGE_GCROOT" "$IMAGE_ID_FILE" "$ROOTFS_GCROOT"
  fi

  IMAGE_OUT=""
  BUILD_MS=0
  IMAGE_ID=""
  ROOTFS_OUT=""
  ROOTFS_IMAGE_ARG=""
  ROOTFS_RUN_MODE=""
  LOAD_MS=0

  if [ "$MODE" = "podman-rootfs" ]; then
    prepare_rootfs_artifact
  else
    prepare_stream_image_artifact
    load_runtime_image_id
  fi

  PREP_END_MS="$(now_ms)"
  PREP_TOTAL_MS="$((PREP_END_MS - RUN_START_MS))"
  if [ "$MODE" = "podman-rootfs" ]; then
    perf_log "prep total: $(format_duration_ms "$PREP_TOTAL_MS") (store=$(format_duration_ms "$STORE_ADD_MS"), build=$(format_duration_ms "$BUILD_MS"), mode=podman-rootfs)"
  else
    perf_log "prep total: $(format_duration_ms "$PREP_TOTAL_MS") (store=$(format_duration_ms "$STORE_ADD_MS"), build=$(format_duration_ms "$BUILD_MS"), load=$(format_duration_ms "$LOAD_MS"), mode=docker-oci)"
  fi
}
