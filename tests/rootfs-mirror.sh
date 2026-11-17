#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/bin/lib/rootfs.sh"
perf_log() { :; }
fail() { echo "[fail] $*" >&2; exit 1; }
fixture="$(mktemp -d)"
trap 'chmod -R u+rwX "$fixture"; rm -rf "$fixture"' EXIT
CACHE_DIR="$fixture/cache"
source_rootfs="$fixture/source-rootfs"
mkdir -p "$source_rootfs/bin" "$source_rootfs/etc"
for executable in sh catatonit agent-rootless-linux-entrypoint agent-remote-entrypoint; do
  printf '#!/bin/sh\nexit 0\n' > "$source_rootfs/bin/$executable"
  chmod 0555 "$source_rootfs/bin/$executable"
done
chmod 0555 "$source_rootfs" "$source_rootfs/etc" "$source_rootfs/bin"

mirror="$(prepare_writable_rootfs_mirror "$source_rootfs" test)"
[ -x "$mirror/bin/catatonit" ] || fail 'fresh mirror lacks init'
printf sentinel > "$mirror/cache/sentinel"
[ "$(prepare_writable_rootfs_mirror "$source_rootfs" test)" = "$mirror" ] || fail 'cache path changed'
[ -f "$mirror/cache/sentinel" ] || fail 'valid cache was rebuilt'

# Reproduce a ready marker alongside an incomplete mirror.
chmod u+w "$mirror/bin"
rm -rf "$mirror/bin"
mirror="$(prepare_writable_rootfs_mirror "$source_rootfs" test)"
[ -x "$mirror/bin/catatonit" ] || fail 'ready marker allowed missing bin to be reused'

# A directory left by an interrupted copy must not be marked ready as-is.
rm "$mirror.ready"
chmod u+w "$mirror/bin"
rm "$mirror/bin/catatonit"
mirror="$(prepare_writable_rootfs_mirror "$source_rootfs" test)"
[ -x "$mirror/bin/catatonit" ] || fail 'incomplete directory was published instead of the fresh copy'

# Force-rebuild must also replace an otherwise valid mirror.
printf stale > "$mirror/cache/stale"
AGENT_FORCE_REBUILD=1 prepare_writable_rootfs_mirror "$source_rootfs" test > /dev/null
[ ! -e "$mirror/cache/stale" ] || fail 'force-rebuild retained old mirror'

# Two source derivations must never share a mirror, even with the same caller key.
mkdir "$fixture/other-rootfs"
cp -a "$source_rootfs/." "$fixture/other-rootfs/"
other_mirror="$(prepare_writable_rootfs_mirror "$fixture/other-rootfs" test)"
[ "$other_mirror" != "$mirror" ] || fail 'source roots share a cache entry'

# Invalid sources must fail before a ready marker is published.
mkdir "$fixture/invalid-rootfs"
if prepare_writable_rootfs_mirror "$fixture/invalid-rootfs" invalid > "$fixture/output" 2> "$fixture/error"; then
  fail 'source without executables was accepted'
fi
[[ "$(cat "$fixture/error")" == *'required rootfs executable'* ]] || fail 'missing source diagnostic'

# Concurrent launches must share one complete publication.
other_copy="$CACHE_DIR/rootfs-cache/unrelated-key.tmp.active"
mkdir "$other_copy"
printf active > "$other_copy/sentinel"
prepare_writable_rootfs_mirror "$source_rootfs" concurrent > "$fixture/first" &
first_pid=$!
prepare_writable_rootfs_mirror "$source_rootfs" concurrent > "$fixture/second" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
[ "$(cat "$fixture/first")" = "$(cat "$fixture/second")" ] || fail 'concurrent cache paths differ'
[ -x "$(cat "$fixture/first")/bin/catatonit" ] || fail 'concurrent mirror incomplete'
[ -f "$other_copy/sentinel" ] || fail 'another mirror copy was removed by cleanup'

# Copy failures must leave neither a usable cache entry nor a ready marker.
cp() { command cp "$@"; return 1; }
if prepare_writable_rootfs_mirror "$source_rootfs" copy-failure > "$fixture/output" 2> "$fixture/error"; then
  fail 'failed copy was accepted'
fi
unset -f cp
[ -z "$(find "$CACHE_DIR/rootfs-cache" -name 'copy-failure*' ! -name '*.lock' -print)" ] || fail 'failed copy left a mirror or ready marker'
echo '[pass] rootfs mirror integrity and publication'
