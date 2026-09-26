# Configuration Reference

This document is the reference for launcher knobs, tool config selectors, auth selectors, helper behavior, and compatibility aliases. For a task-oriented entry point, start at [../README.md](../README.md). For concrete workflows, use [RECIPES.md](RECIPES.md).

## Recommended Defaults

For most projects, start with:

```sh
AGENT_CONTAINER_API=auto
AGENT_NEED_HELPER=1
AGENT_DEV_ENV=host-helper
CODEX_CONFIG=project
CODEX_AUTH=work
```

Bootstrap the project defaults file with:

```sh
./scripts/agent init
./scripts/agent init --force
./scripts/agent init --stdout
```

The launcher loads defaults from:
1. `AGENT_PROJECT_CONFIG_FILE`
2. The nearest `.agent-sandbox.env`, searching from the launch directory upward to the filesystem root.

Only one file is discovered; files in parent directories are not automatically merged. Config discovery is independent of `AGENT_PROJECT_ROOT` and Git worktree roots. An explicit `AGENT_PROJECT_CONFIG_FILE` must exist.

To inherit shared defaults, add `AGENT_CONFIG_EXTENDS=../.agent-sandbox.env` to a worktree's config. The path is relative to the declaring file (absolute paths are also accepted). Parents load before children; child assignments replace parent values, including the entire `AGENT_EXTRA_ENV` block. Missing parents and inheritance cycles are errors. The inheritance path is literal, without variable expansion.

Precedence is built-in defaults, inherited config, selected config, then process environment. Existing environment variables, including empty values, always win over file values. Duplicate keys within one file are errors. Files are read on each launch; edits affect new containers, not already running containers.

Run `agent config explain` to see the launch directory, project root, loaded files in order, and sources of configured settings. Values are always redacted, and environment overrides identify the file assignment they replace.

## High-Impact Knobs

| Variable | Default | Allowed values | Effect |
| --- | --- | --- | --- |
| `AGENT_SANDBOX_PROFILE` | `default` | `default`, `rootless-linux`, `firecracker-host` | Selects the sandbox capability profile |
| `AGENT_PERMISSION_POLICY` | `container`; `native` on `rootless-linux` | `container`, `native` | Selects shared tool permission handling; see [Agent permission policy](#agent-permission-policy) |
| `AGENT_RUNTIME` | auto-detect | `podman`, `docker` | Selects the outer runtime |
| `AGENT_CONTAINER_API` | `none` | `none`, `auto`, `podman-session`, `podman-host`, `docker-host` | Controls inner container API exposure |
| `AGENT_DEV_ENV` | `host-helper` | `host-helper`, `none` | Enables or disables the host direnv snapshot helper |
| `AGENT_NEED_HELPER` | `1` | `0`, `1` | Enables or disables the narrow host-backed Nix helper |
| `AGENT_CODEX_VERSION` | unset | exact npm version, `latest` | Pins the sandboxed `@openai/codex` package; unset or `latest` keeps auto-update behavior |
| `CODEX_CONFIG` | `host` | `host`, `project`, `fresh`, `<path>` | Selects Codex home; `project` uses `$AGENT_PROJECT_ROOT/.codex` |
| `CLAUDE_CONFIG` | `host` | `host`, `project`, `fresh`, `<path>` | Selects Claude config root |
| `OPENCODE_CONFIG` | `host` | `host`, `project`, `fresh`, `<path>` | Selects OpenCode config root |
| `CODEX_AUTH` | unset | slot name, file path | Overlays Codex credentials |
| `CLAUDE_AUTH` | unset | slot name, file path | Overlays Claude credentials |
| `OPENCODE_AUTH` | unset | slot name, file path | Overlays OpenCode credentials |

## Runtime And Project Resolution

| Variable | Default | Effect |
| --- | --- | --- |
| `AGENT_PROJECT_ROOT` | enclosing git top-level or cwd | Host project root |
| `AGENT_PROJECT_NIX_DIR` | `$AGENT_PROJECT_ROOT/nix` | Project contract directory |
| `AGENT_SANDBOX_FLAKE_REF` | local checkout or `github:zvictor/agent-sandbox` | Sandbox flake source |
| `AGENT_CACHE_DIR` | `$XDG_CACHE_HOME/agent-sandbox` or host-home fallback | Cache root for artifacts, helpers, and tool installs |
| `AGENT_HOST_HOME` | host home fallback | Used for discovering config roots, `.gitconfig`, and auth bases |
| `AGENT_PROJECT_CONTRACT_FILES` | unset | Extra project-relative files or directories staged for package evaluation |

For a project without `flake.lock`, a string-form `fetchTarball "..."` in `shell.nix` is pinned once under `AGENT_CACHE_DIR/project-contracts`. Its unpacked Nix store path is held by a project-scoped host GC root, and the pin is reused without a network check on later launches. Remove the exact pin file reported in the startup log to resolve the URL again. Locks created by older launchers without a retained store path must be removed once before reuse.

## Runtime Behavior

### Agent permission policy

`AGENT_PERMISSION_POLICY=container|native` applies to all supported tool launchers, including shortcuts, direct `agent <tool>` launches, remote Codex, and child CLIs started through the container's PATH. Standard and Firecracker profiles default to `container`; `rootless-linux` defaults to `native`. An explicit value overrides the profile default.

`container` selects each tool's documented permissive launch mode. The outer runtime remains the isolation boundary. Explicit upstream deny rules and mandatory upstream policies may still apply; tools other than Codex can expose interactive mode switches. `native` adds no bypass flags or permission environment overrides and preserves caller settings. It does not enable a sandbox where the tool has none, or undo bypass flags the caller explicitly supplies.

| Tool | Container adapter |
| --- | --- |
| Codex | `--yolo`, plus generated requirements restricting permission selection to `:danger-full-access` and approvals to `never` |
| Claude | `--dangerously-skip-permissions` and session settings disabling its Bash sandbox |
| OpenCode | `OPENCODE_PERMISSION='{"*":"allow"}'` |
| Antigravity | `--dangerously-skip-permissions`; requesting its terminal sandbox conflicts with this policy |
| OMP, Command Code | `--yolo`; upstream explicit restrictions remain effective |
| CodeMachine | Child CLIs inherit the policy; native mode is unsupported because CodeMachine hardcodes bypass flags |

Conflicting permission flags or OpenCode environment overrides fail with guidance to select `native`. For example:

```sh
AGENT_PERMISSION_POLICY=native agent codex --sandbox workspace-write --ask-for-approval on-request
AGENT_PERMISSION_POLICY=native agent claude --permission-mode default
```

Codex container policy requires version 0.138.0 or later. Its policy directory is regenerated for each launch under the runtime lease and mounted read-only at `/etc/codex`; model, hook, and other personal preferences remain in the normal user/project layers. The previous `.agent-sandbox/codex/managed_config.toml` copy is no longer loaded. Existing copies and legacy cache config remain available for recovery: move any settings unique to those files into a supported user or project config.

`agent doctor`, `--verbose`, and `--json` report the policy and its source. Native Codex workspace access is incompatible with protected workspace metadata symlinks such as `.codex -> ../.codex`. Explicit `--sandbox workspace-write` launches are rejected early for known symlinked project metadata; implicit policies selected in Codex config can still fail inside Codex. Native read-only mode can behave differently. Keep a real project `.codex/sessions` directory; container mode preserves supported shared `.codex` symlinks.

The PID-1 reaper is mandatory infrastructure, not a configuration option.
Default, Firecracker, Docker, and remote launches use the engine's `--init`
facility. The `rootless-linux` profile instead runs the immutable Catatonit
binary from its rootfs as PID 1. Its root-unmapped user namespace cannot accept
Podman's injected `/run/podman-init` bind mount. A runtime that cannot provide
the selected init fails during container creation.

| Variable | Default | Effect |
| --- | --- | --- |
| `AGENT_FORCE_TTY` | auto | Force `-t` when set to `1` |
| `AGENT_MEMORY_LIMIT` | `4g` | Container memory limit |
| `AGENT_CPU_LIMIT` | `2` | Container CPU limit |
| `AGENT_PIDS_LIMIT` | `512` | Container PID limit |
| `AGENT_WORKSPACE_PATH` | current directory | Workspace mounted at the same absolute path inside the sandbox |
| `AGENT_PODMAN_ROOTFS_MODE` | `auto` | Podman rootfs mode: `auto`, `overlay`, or `mirror`; `rootless-linux` requires `auto` or `mirror` and always selects the mirror |
| `AGENT_ALLOW_SUDO` | `0` | Enables container-local sudo when set to `1` |
| `AGENT_DISABLE_AUDIO` | `0` | Disables automatic audio forwarding (PipeWire, PulseAudio, and ALSA `/dev/snd`) |
| `AGENT_DISABLE_CLIPBOARD` | `0` | Disables automatic clipboard/display forwarding (Wayland socket and X11 `/tmp/.X11-unix`) |
| `AGENT_PERF_LOG` | `1` | Enable or disable timing logs |
| `AGENT_FORCE_REBUILD` | `0` | Rebuild cached runtime artifacts |
| `AGENT_NIX_EXPERIMENTAL_FEATURES` | `nix-command flakes` | Extra Nix experimental features for launcher commands |
| `AGENT_HELPER_TMPDIR` | `$AGENT_CACHE_DIR/tmp` | Temp directory for helper runs |
| `AGENT_DEBUG` | `0` | Print resolved paths and execution details with container environment values redacted |

### Temporary storage

Inside a newly launched Podman sandbox, run `df -h /tmp` to see the capacity
of the host cache filesystem. `/tmp` is a private, disk-backed bind mount under
`$AGENT_CACHE_DIR/tmp/sandboxes/` (normally
`~/.cache/agent-sandbox/tmp/sandboxes/`), not the project's `.tmp` directory.
Each foreground sandbox gets its own directory; a named remote sandbox keeps
its directory until remote teardown. The mounted directory has mode `1777`
and uses `exec,nosuid,nodev` mount options.

There is no separate 512 MiB ceiling: available space and filesystem quotas on
the cache filesystem apply. Choose a disk-backed cache filesystem that permits
execution; placing the cache on tmpfs still consumes memory. Disk-backed files
can also use memory through the kernel's page cache, so this is not an OOM fix.
An explicit `TMPDIR` override still directs applications elsewhere.

Temporary storage follows the runtime lease: it is removed after confirmed
container teardown, retained if the runtime cannot confirm teardown, and retried
by foreground stale-lease pruning on later launches. Cleanup restores owner
access on temporary directories without changing file permissions or following
symlinks. Ownership or filesystem errors may still prevent removal; failures
retain the lease and warn without replacing the agent's exit status or skipping
other launcher cleanup. No project temporary files are migrated or
deleted. These changes apply to new sandboxes only.

Docker retains its 512 MiB tmpfs because its bind-mount interface does not expose
the equivalent per-mount security flags. `AGENT_HELPER_TMPDIR` controls helper
temporary files, not the sandbox's `/tmp`.

## Remote Sandboxes

Remote mode is documented in [REMOTE.md](REMOTE.md). It creates one durable
Podman pod per worktree and exposes the sandbox through a Tailscale sidecar.

| Variable | Default | Effect |
| --- | --- | --- |
| `AGENT_REMOTE_NAME` | derived from worktree path | Stable remote endpoint name |
| `AGENT_REMOTE_HOSTNAME` | `AGENT_REMOTE_NAME` | Tailscale hostname for the sidecar |
| `AGENT_REMOTE_USER` | `codex` | SSH login user inside the runtime container |
| `AGENT_REMOTE_AUTHORIZED_KEYS_FILE` | host `~/.ssh/authorized_keys` when present | Public keys allowed to SSH into the sandbox |
| `AGENT_REMOTE_AUTHORIZED_KEY` | unset | Single public key allowed to SSH into the sandbox |
| `AGENT_REMOTE_TS_AUTHKEY_FILE` | unset | File containing the Tailscale auth key for first start |
| `AGENT_REMOTE_TS_AUTHKEY` | unset | Tailscale auth key for first start |
| `AGENT_REMOTE_TS_CLIENT_ID` / `AGENT_REMOTE_TS_CLIENT_SECRET` | unset | Tailscale OAuth credentials for first start |
| `AGENT_REMOTE_TAILSCALE_TAG` | `tag:codex-agent` | Tag advertised by the sidecar |
| `AGENT_REMOTE_TAILSCALE_IMAGE` | `docker.io/tailscale/tailscale:latest` | Tailscale sidecar image |
| `CODEX_CONFIG` in remote mode | `project` | Codex config/session root for remote sandboxes; set `host` explicitly to share host `~/.codex` |
| `AGENT_REMOTE_ALLOW_CONTAINER_API` | `0` | Allow remote mode to inherit `AGENT_CONTAINER_API` |
| `AGENT_REMOTE_ALLOW_NEED_HELPER` | `0` | Allow remote mode to use the host Nix helper |
| `AGENT_REMOTE_ALLOW_NIX_DAEMON` | `0` | Allow raw Nix daemon socket access in remote mode |
| `AGENT_REMOTE_ALLOW_EXTRA_MOUNTS` | `0` | Allow `AGENT_EXTRA_MOUNTS` in remote mode |
| `AGENT_REMOTE_ALLOW_EXTRA_DEVICES` | `0` | Allow extra devices or `AGENT_ALLOW_KVM` in remote mode |
| `AGENT_REMOTE_ALLOW_AUTO_MOUNTS` | `0` | Allow `AGENT_AUTO_MOUNT_DIRS` in remote mode |
| `AGENT_REMOTE_ALLOW_EXTRA_ENV` | `0` | Allow `AGENT_EXTRA_ENV` in remote mode |
| `AGENT_REMOTE_ALLOW_HOST_ENV` | `0` | Allow broad host environment passthrough in remote mode |
| `AGENT_REMOTE_FORWARD_SSH_AGENT` | `0` | Forward the host SSH agent into the remote runtime |
| `AGENT_REMOTE_FORWARD_AUDIO` | `0` | Forward host audio into the remote runtime |
| `AGENT_REMOTE_FORWARD_CLIPBOARD` | `0` | Forward host clipboard/display into the remote runtime |
| `AGENT_REMOTE_ALLOW_PRIVILEGED_HOST_CONTROL` | unset | Set to `I_UNDERSTAND` to allow non-interactive `firecracker-host` remote startup |

### Rootless Linux Profile

Use `AGENT_SANDBOX_PROFILE=rootless-linux` for unprivileged workloads that use
inherited cgroup-v2 delegation. A private container-local `systemd --user`
manager starts the agent in a delegated scope; the profile does not provide
a complete user-session bus or a supported transient-service workflow with
stdio forwarding.

Use inherited delegation for local execution. Keep full service/acquisition
conformance gates on a separate disposable CI host provisioned for that workflow.
A passing inherited-delegation test does not qualify service acquisition,
including acquisition from a transport service with insufficient delegation.

The host contract is deliberately strict:

- Linux with unified cgroup v2 and writable `cgroup.kill` in the private manager subtree
- a non-root launcher user
- an active `systemd --user` manager and owned `XDG_RUNTIME_DIR`
- delegated `cpu`, `memory`, and `pids` controllers
- unprivileged user namespaces
- local rootless Podman
- `pasta` (preferred) or `slirp4netns` for an isolated rootless network namespace

The profile supports only local Podman rootfs mode. It rejects Docker,
remote-container mode, rootful Podman, root execution, and
`AGENT_ALLOW_SUDO=1`. It also rejects extra/automatic mounts, extra devices,
KVM, container API exposure, and the Nix daemon socket. Podman itself runs in a
transient delegated host user scope with `--cgroups=split`,
`--cgroupns=private`, a rootfs-supplied Catatonit PID-1 reaper, and Podman
systemd mode disabled. The profile always prepares a cached local rootfs mirror
and runs it with `:O`: the user-owned baseline lets crun create generic mount
targets while the overlay upper keeps runtime filesystem changes ephemeral.
An explicit `AGENT_PODMAN_ROOTFS_MODE=overlay` is rejected. Only
`/sys/fs/cgroup` is unmasked inside that private namespace so the
container-local user manager can manage its delegated subtree.
Podman's exact default `/proc` cover-mount paths are also unmasked so Linux's
`mount_too_revealing()` guard permits a nested user/PID namespace to mount its
own procfs. The list is explicit rather than `/proc/*` or `unmask=ALL`, and the
container still receives a private PID namespace—not a host `/proc` bind.

Before launching the agent, the entrypoint checks that `basic.target`,
`exit.target`, `systemd-exit.service`, and `shutdown.target` are readable in
the immutable user-unit directory and load successfully in the private manager.
Missing shutdown units fail startup instead of leaving an unusable exit path.

Codex launches its native executable directly, without a persistent Bun wrapper.
The supervisor waits using an interruptible shell wait with stdin preserved;
SIGINT, SIGTERM, or SIGHUP can start teardown even if the agent is stuck.
After the agent exits, its status is preserved while the private manager gets
a five-second shutdown grace period. A failed shutdown request or an expired
deadline triggers `cgroup.kill` on that manager's subtree, including remaining
descendants. The entrypoint retains a descriptor for this exact subtree; it
does not kill host user units or unrelated PIDs. PID 1 and the supervisor live
in a sibling cgroup. Repeated Ctrl+C does not restart cleanup. After one more
second, any still-populated subtree is reported and left to container teardown,
without an unbounded process wait.

If shutdown reports missing units, start a new sandbox using the updated
launcher/runtime; existing sessions keep their original entrypoint. An OOM
message is a separate memory-pressure diagnostic, not proof that Codex was
the killed process. These shutdown safeguards do not change memory limits.

The user namespace maps only the invoking host user to its normal container
UID/GID; container UID/GID 0 remain unmapped. This preserves host-user
ownership of the delegated cgroup instead of asking the OCI runtime to assign
it to container root.
The profile refuses to fall back to the host network namespace when neither
supported rootless network backend is available.
Inside the container, a generic private `systemd --user` manager owns the
agent's transient delegated scope. `systemd-run` registers that scope through
the manager's private socket. A generic launcher then moves itself into an
agent payload leaf, verifies that the delegated parent is empty, activates the
`cpu`, `memory`, and `pids` controllers on that parent, and replaces itself with
the agent. The inherited terminal and exit status are preserved without a user
message bus. `AGENT_DELEGATED_CGROUP` identifies the empty parent as bounded
informational metadata; it grants no authority beyond the cgroup filesystem's
existing ownership. The host user bus and manager sockets are never mounted
into the container.

In particular, `systemd-run --user --wait --collect --pipe --service-type=exec`
is outside the supported profile contract. The profile does not provision a
session-bus broker at `$XDG_RUNTIME_DIR/bus`; successful `systemctl --user`
queries through `$XDG_RUNTIME_DIR/systemd/private` do not establish support for
that service path. Setting `DBUS_SESSION_BUS_ADDRESS` to the private manager
socket is not a supported workaround. Substituting a scope for a service also
does not qualify service/acquisition conformance coverage.

The image supplies upstream Bubblewrap 0.12.0. Before the agent starts, the
private session verifies zero effective capabilities, writable delegated CPU,
memory, and PID controls, and a nested unprivileged Bubblewrap user/PID
namespace with a freshly mounted private procfs.
Any failure is terminal; this profile has no sudo, rootful, or compatibility
fallback.

Run the end-to-end capability probe on a candidate host with:

```sh
AGENT_RUN_ROOTLESS_LINUX_TESTS=1 bash tests/regression.sh
```

### Firecracker Host Profile

Use `AGENT_SANDBOX_PROFILE=firecracker-host` when the agent must run host-level
Firecracker smoke tests from inside the sandbox.

This profile supports one backend: Linux rootful Podman through
`sudo -n podman`. It rejects Docker, remote Podman, rootless Podman, non-Linux
hosts, and explicit container API modes. `AGENT_CONTAINER_API=auto` resolves to
`none` in this profile.

Inside the launched sandbox, `podman` is a profile-specific wrapper around the
image's fixed Podman package and `/agent-sudo/bin/sudo -n`. Local OCI image
build/run validation uses rootful Podman with an isolated `vfs` store at
`/cache/agent-firecracker-podman` and managed network definitions under that
same state directory, so it does not require rootless `/etc/subuid` or
`/etc/subgid` mappings, nested overlay support, or mutable `/etc/containers`
state.

The launcher preflights the host before building/running the sandbox:
- the launcher is not itself running through `sudo` from a non-root operator
- `sudo -n true`
- `sudo -n podman info`
- rootful Podman
- `/dev/kvm`
- `/dev/net/tun`
- cgroup v2 at `/sys/fs/cgroup`
- root can create cgroup v2 child directories
- root can write cgroup v2 control files
- root can write and chown files under the selected workspace

The launched container uses privileged host-control semantics:
- `--privileged`
- `--cap-add=NET_ADMIN` for tap setup by the host-UID command process
- `--userns=host`
- `--cgroupns=host`
- `--network=host`
- `/dev/kvm`
- `/dev/net/tun`
- writable `/sys/fs/cgroup`

The agent process still runs as the host UID/GID for normal workspace writes.
In-container `sudo` is required and is enabled by this profile.
Run the launcher as the operator user; the profile invokes `sudo -n podman`
internally. A top-level `sudo ./scripts/codex` launch is unsupported because
it changes host auth/config and cache ownership semantics.

## Tool Config Roots And Auth

Tool config mounts:
- `codex`: every selected user home mounts at `/cache/.codex`; project mode mounts host `~/.codex` there, leaves `$AGENT_PROJECT_ROOT/.codex` visible as the project layer, overlays `$AGENT_PROJECT_ROOT/.codex/sessions` at `/cache/.codex/sessions`, keeps the SQLite resume inventory in the project layer through `CODEX_SQLITE_HOME`, and mounts freshly generated runtime policy at `/etc/codex` from the container's runtime lease
- `opencode`: host config root to container `~/.config/opencode`
- `antigravity`: host `~/.gemini` to container `~/.gemini`; the native `agy` binary is cached under `/cache/antigravity`
- `claude`: host config root to container `~/.claude`
- `omp`: host `~/.omp` to container `~/.omp`
- `codemachine`: mounts Codex, OpenCode, and Claude config roots together

The project `.codex` may be a symlink to an existing directory, including a shared parent directory such as `main/.codex -> ../.codex`. The launcher exposes the resolved config directory and any required symlink lookup path inside the container; it does not mount the entire parent directory. The host symlink stays intact. Sessions remain accessible at `$AGENT_PROJECT_ROOT/.codex/sessions`, and writes follow the link into the shared directory. `CODEX_SQLITE_HOME` continues to use the project `.codex` path.

Broken or looping links, non-directory targets, and user/project config layers that refer to the same directory are rejected before config preparation. The `sessions` entries within the user and project `.codex` directories and `.agent-sandbox/codex` must still be real directories.

Codex hooks follow the standard configuration layers:

- user hook: host `~/.codex/hooks.json`, mounted at `/cache/.codex/hooks.json`
- project hook: `$AGENT_PROJECT_ROOT/.codex/hooks.json`, available after the project is trusted

Both matching hook layers run once in project mode.

Config selectors:

| Variable | Modes |
| --- | --- |
| `CODEX_CONFIG` | `host`, `project`, `fresh`, `<path>` |
| `CLAUDE_CONFIG` | `host`, `project`, `fresh`, `<path>` |
| `OPENCODE_CONFIG` | `host`, `project`, `fresh`, `<path>` |

Auth selectors:

| Variable | Meaning |
| --- | --- |
| `CODEX_AUTH` | named slot like `work` or an explicit credential file path |
| `CLAUDE_AUTH` | named slot like `work` or an explicit credential file path |
| `OPENCODE_AUTH` | named slot like `work` or an explicit credential file path |
| `AGENT_AUTH_HOME` | base directory for managed slots; defaults to `~/.local/share/agent-sandbox/auth` |
| `CODEX_AUTH_BASE_DIR` | override Codex slot directory |
| `CLAUDE_AUTH_BASE_DIR` | override Claude slot directory |
| `OPENCODE_AUTH_BASE_DIR` | override OpenCode slot directory |
| `PI_CODING_AGENT_DIR` | host OMP agent directory; defaults to `~/.omp/agent` |

Examples:

```sh
CODEX_CONFIG=project
CODEX_CONFIG=fresh
CODEX_CONFIG=/tmp/other-codex

CODEX_AUTH=work
CODEX_AUTH=/path/to/auth.json
```

Codex package version:

```sh
AGENT_CODEX_VERSION=0.141.0 ./scripts/codex resume <session-id>
AGENT_CODEX_VERSION=latest ./scripts/codex
```

## Container API Access

| Variable | Default | Effect |
| --- | --- | --- |
| `AGENT_CONTAINER_API` | `none` | Chooses the container API exposure mode |
| `AGENT_CONTAINER_API_TTL` | `900` | Inactivity timeout for `podman-session` |
| `AGENT_CONTAINER_API_WAIT_SECONDS` | `30` | Socket readiness timeout for `podman-session` |
| `AGENT_CONTAINER_API_RESET` | `0` | Clears cached `podman-session` state before restart |

Mode guidance:
- `none`: safest when you do not need inner container workflows
- `auto`: preferred high-level choice for Testcontainers
- `podman-session`: isolated rootless Podman API service under `AGENT_CACHE_DIR`
- `podman-host`: direct host Podman socket exposure
- `docker-host`: direct host Docker socket exposure

Compatibility aliases:
- `AGENT_ALLOW_PODMAN_SOCKET=1`: alias for `AGENT_CONTAINER_API=podman-host`
- `AGENT_ALLOW_DOCKER_SOCKET=1`: alias for `AGENT_CONTAINER_API=docker-host`
- `AGENT_ALLOW_NIX_DAEMON_SOCKET=1`: explicit host Nix daemon socket mount

These widen the sandbox boundary substantially.

## Dev Environment Snapshot

| Variable | Default | Effect |
| --- | --- | --- |
| `AGENT_DEV_ENV` | `host-helper` | Enables host direnv snapshotting |
| `AGENT_DIRENV_NIX_PATH` | unset | Forces a specific nixpkgs tree for host-helper resolution |

With `AGENT_DEV_ENV=host-helper`, the launcher resolves a clean host `direnv` snapshot before the container starts, caches the filtered result, and injects it into the sandbox at startup. There is no live bridge back to host direnv; restart the session to refresh `.envrc` changes.

When the snapshot includes `PATH`, the sandbox's base commands and compatibility wrappers (`git`, `sh`, `nix`, `nix-shell`, and `need`) stay first. Project-local bins and the dev-environment `PATH` come before ambient `need inject` bins and image fallback paths. If `AGENT_ALLOW_SUDO=1`, `/agent-sudo/bin` is inserted immediately after those base commands.

For `.envrc` files that use `use nix` with `<nixpkgs>`, the helper first reuses the current host `NIX_PATH` if present, then falls back to the sandbox flake's locked `nixpkgs` input.

## Nix Helper And Command Expansion

| Variable | Default | Effect |
| --- | --- | --- |
| `AGENT_NEED_HELPER` | `1` | Enables the narrow host-side helper worker |
| `AGENT_NEED_TIMEOUT` | `600` | Request timeout for `need` |
| `AGENT_NEED_BOOTSTRAP_INDEX` | `1` | Starts background `need update-index` when needed |
| `AGENT_NEED_INDEX_URL` | nix-index release URL | Override the downloaded nix-index database |
| `AGENT_NEED_CACHE_DIR` | `$XDG_CACHE_HOME/need` | Cache root for helper materializations |
| `AGENT_NEED_TOOLS_DIR` | project-scoped bin dir under `$XDG_CACHE_HOME/need` | Launcher directory for `need inject` |
| `AGENT_NEED_INDEX_DIR` | nix-index cache dir | Location of the local command index |

Common commands:

```sh
need update-index
need pnpm
need run pnpm -- pnpm -v
need inject pnpm
need clear
need clear --legacy
need clear --all
```

Bare `need <command>` lookups use `nixos-unstable` by default. Use `nixpkgs#...` when you explicitly want the stable channel, and keep using any other explicit ref exactly as passed.

`need inject` is project-scoped by default. `need clear` removes only the current injected-bin scope, `need clear --legacy` removes the old shared injected-bin directory, and `need clear --all` removes all `need` cache state under `AGENT_NEED_CACHE_DIR`.

Each launch has a host-owned runtime lease. Its roots remain outside the
container; `/run/agent-runtime-receipts` is mounted read-only and contains the
lease manifest plus closure receipts. `AGENT_RUNTIME_LEASE_ID`,
`AGENT_RUNTIME_RECEIPTS_DIR`, and `AGENT_NEED_HELPER_DIR` are runtime-owned and
cannot be overridden through `AGENT_EXTRA_ENV` or host passthrough.
For foreground Podman sessions, the lease is bound to the generated container
identity before launch. Launcher or coordinator exit cannot release the lease
while that container still exists; cleanup and stale pruning require Podman to
confirm teardown. A detached host guard performs that confirmation and releases
the lease after an orphaned foreground launcher is gone. The `rootless-linux`
entrypoint additionally verifies the read-only mount and every rootfs closure
path before it starts the agent.

Materialization succeeds only after Nix has created a permanent root at its
final pathname and the helper has published a receipt. Cache entries from a
different lease are rejected. When enabled, the request worker remains
available until the runtime lease is released.

The sandbox also prefers compatibility shims over sandbox-specific instructions when possible:
- `nix shell <installable> --command ...`
- `nix-shell -p <pkg> --run ...`
- `podman ...`
- `docker ...`

## Nix Binary Cache Inside The Container

| Variable | Default | Effect |
| --- | --- | --- |
| `AGENT_USE_LOCAL_BINCACHE` | `1` | Enables `file:///nixcache` |
| `AGENT_NIX_BINCACHE_DIR` | unset | Host directory mounted read-only at `/nixcache` |
| `AGENT_LOCAL_BINCACHE_ALLOW_UNSIGNED` | `0` | Set to `1` to allow unsigned local substitutes |

## Mounts And Environment Passthrough

| Variable | Default | Effect |
| --- | --- | --- |
| `AGENT_EXTRA_ENV` | unset | Extra container `KEY=VALUE` pairs; use one per line in a quoted multiline value, or commas in a single-line value |
| `AGENT_AUTO_MOUNT_DIRS` | unset | Auto-mount ancestor directories by name |
| `AGENT_EXTRA_MOUNTS` | unset | Raw mount specs in `host:container[:options]` format |
| `AGENT_EXTRA_DEVICES` | unset | Raw device specs passed through as `--device` |
| `AGENT_PASS_ENV_PREFIXES` | built-in list | Prefixes forwarded from the host environment |

For several variables, use a multiline block in `.agent-sandbox.env`:

```dotenv
AGENT_EXTRA_ENV="
    TMPDIR=$PWD/.tmp
    CODEX_DISCORD_WEBHOOK_URL=<DISCORD_WEBHOOK_URL>
    OPENROUTER_API_KEY=<OPENROUTER_KEY>
    MISTRAL_API_KEY=<MISTRAL_KEY>
"
```

Each nonblank line must contain `KEY=VALUE`, with a shell-style variable name (`[A-Za-z_][A-Za-z0-9_]*`). Indentation before the key is ignored; spaces after `=` are part of the value. Empty values and additional `=` characters are supported. The entries are injected into the container, not loaded as host settings. Creating directories such as `$PWD/.tmp` remains your responsibility.

In a multiline value, commas are literal data: `LABELS=one,two` is one assignment. A single-line value instead uses commas as separators, for example `AGENT_EXTRA_ENV="FIRST=one,SECOND=two"`. Do not mix comma-separated assignments with newline-separated assignments in the same value. Repeated `AGENT_EXTRA_ENV=` assignments within one file are errors. A child config replaces the entire inherited block.

Malformed entries and attempts to override runtime-owned variables stop the launch without printing their values. In remote mode, this setting still requires `AGENT_REMOTE_ALLOW_EXTRA_ENV=1`.

Compatibility alias:
- `AGENT_ALLOW_KVM=1`: appends `--device /dev/kvm`

The launcher also synthesizes a read-only `/cache/.ssh` from host SSH client state. It copies host SSH config and known-host files into a runtime dir, excludes private-key material, and makes that runtime dir the container's `~/.ssh`.

If the host `SSH_AUTH_SOCK` points to a live Unix socket, the launcher also bind-mounts it into the container at `/run/host-services/ssh-auth.sock`, sets in-container `SSH_AUTH_SOCK` to that path, and injects that stable socket path ahead of the imported SSH config. The raw host path is not forwarded through environment passthrough.

Use `AGENT_EXTRA_DEVICES` when a workload needs explicit device nodes inside the sandbox, for example nested VM tests on hosts that expose KVM:

```sh
AGENT_ALLOW_KVM=1 ./scripts/codex
AGENT_EXTRA_DEVICES=/dev/kvm ./scripts/codex
```

Default forwarded prefixes include:
- `OPENAI_`
- `ANTHROPIC_`
- `CODEX_`
- `CLAUDE_`
- `OPENCODE_`
- `OMP_`
- `PI_`
- `AGENT_`
- plus a small set of runtime and debugging prefixes

Keep these narrow. They are escape hatches.

## Project Defaults File

The project defaults file accepts `KEY=VALUE` assignments. Values may be unquoted, single-quoted, or double-quoted. Both quote styles support multiple lines. Blank lines and `#` comments outside quoted values are ignored. Only sandbox-related keys are loaded, such as:
- `AGENT_*`
- `CODEX_*`
- `CLAUDE_*`
- `OPENCODE_*`
- `OMP_*`
- `PI_*`
- `TESTCONTAINERS_*`

Example:

```sh
AGENT_CONTAINER_API=auto
AGENT_NEED_HELPER=1
CODEX_CONFIG=project
CODEX_AUTH=work
```

Parsing rules:

- Existing environment values, including empty values, override the file. Child assignments override inherited values; duplicate keys within one file are errors.
- `$VAR` and `${VAR}` expand in all three value forms using exported environment variables and earlier loaded settings. Unknown references stay literal. Expansion happens once: dollar signs and shell-looking text inside substituted environment values remain data.
- Quotes delimit a whole value, not individual entries in `AGENT_EXTRA_ENV`. To include the enclosing quote or a backslash in a quoted value, escape it with a backslash. Other backslash sequences, including `\n`, stay literal; use actual line breaks for multiline values.
- A closing quote can appear at the end of the final value line or on its own line. Only whitespace may follow it. Line breaks and whitespace inside quotes are preserved; the extra-environment list separately ignores blank lines and indentation before keys.
- This file is not sourced as a shell script. Command substitution (`$(...)` or backticks), heredocs, `export`, and append assignments (`KEY+=...`) are unsupported. Use quoted multiline values instead of `$(cat <<EOF ...)`.
- Invalid assignment syntax, unterminated quotes, and command substitution stop parsing with a file and line number, without printing values. Unsupported but syntactically valid top-level keys are skipped with a warning; their quoted contents are never interpreted as separate settings.

Keep config files containing credentials out of version control. For literal double quotes in an extra-environment value, single quotes around the block avoid escaping:

```dotenv
AGENT_EXTRA_ENV='
    LABELS=one,two
    METADATA={"source":"sandbox","enabled":true}
'
```

## Ambient Host Environment

The launcher also reacts to a few standard host variables. These are not treated as part of the primary sandbox API:

- `CONTAINER_HOST`: if set, Podman mode is rejected because local `podman --rootfs` execution is required
- `XDG_RUNTIME_DIR`: used to locate the rootless Podman socket for `podman-host`
- `XDG_CACHE_HOME`: used as the default base for `AGENT_CACHE_DIR`
- `TMPDIR`: used for helper temp files when `AGENT_HELPER_TMPDIR` is unset
- `SSH_AUTH_SOCK`: when it points to a live socket, the host SSH agent is mounted into the sandbox
- `~/.ssh`: copied into a read-only synthesized container `~/.ssh`, excluding private-key files

## Compatibility Aliases

These are still accepted, but they are not the preferred interface:

- `AGENT_SANDBOX_FLAKE`: alias for `AGENT_SANDBOX_FLAKE_REF`
- `CODEX_RUNTIME`: alias for `AGENT_RUNTIME`
- `OMP_CODING_AGENT_DIR`: alias for `PI_CODING_AGENT_DIR`
- `AGENT_ALLOW_PODMAN_SOCKET=1`: alias for `AGENT_CONTAINER_API=podman-host`
- `AGENT_ALLOW_DOCKER_SOCKET=1`: alias for `AGENT_CONTAINER_API=docker-host`
- `AGENT_ALLOW_KVM=1`: alias for `AGENT_EXTRA_DEVICES=/dev/kvm`
