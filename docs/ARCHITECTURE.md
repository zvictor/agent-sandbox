# Architecture

This document explains how the launcher resolves a project, prepares artifacts, starts helper services, and runs the final container. For setup guidance, start at [../README.md](../README.md).

## Mental Model

`agent-sandbox` does five things in sequence:

1. Resolve the host project, sandbox flake, runtime, and tool/config/auth selectors.
2. Stage the project's Nix package contract into the store.
3. Prepare the runtime artifact: Podman `rootfs` or Docker OCI `streamImage`.
4. Start optional helper services such as the narrow Nix helper, direnv snapshot helper, or isolated Podman session API.
5. Assemble mounts, env vars, and entrypoint args, then run the selected tool inside the container.

Remote mode uses the same project/config/artifact preparation path, but changes
the final lifecycle: it creates a stable Podman pod, runs the agent rootfs
container detached with an OpenSSH/tmux entrypoint, and adds a Tailscale
sidecar that forwards tailnet TCP/22 to the runtime container's local SSH port.
See [REMOTE.md](REMOTE.md).

## Launcher Flow

High-level flow:

```text
resolve CLI command
  -> resolve project root and project defaults
  -> resolve runtime and sandbox flake
  -> stage project contract input
  -> add staged contract to the Nix store
  -> build or reuse the selected runtime artifact
  -> start helper services if enabled
  -> resolve tool config and auth mounts
  -> build container args
  -> run the tool container
```

The main entrypoint is [`bin/agent`](../bin/agent).

The final container runtime is launched under a small supervisor whose
`argv[0]` is the selected tool name (`codex`, `claude`, `opencode`, and so
on). The runtime executable itself still receives its normal command name and
arguments, but process observers that inspect the foreground job can see the
logical agent instead of only `podman` or `docker`.

## Major Components

### Entry Points

- [`bin/agent`](../bin/agent): main launcher
- [`scripts/agent`](../scripts/agent): thin local-checkout entrypoint
- [`scripts/codex`](../scripts/codex), [`scripts/claude`](../scripts/claude), [`scripts/opencode`](../scripts/opencode), [`scripts/codemachine`](../scripts/codemachine), [`scripts/omp`](../scripts/omp): tool-specific wrappers
- [`flake.nix`](../flake.nix): flake packages and apps that delegate to the same scripts

### Runtime Libraries

- [`bin/lib/environment.sh`](../bin/lib/environment.sh): project root, config loading, runtime resolution, cache dirs, store input
- [`bin/lib/project_contract.sh`](../bin/lib/project_contract.sh): contract staging and allowlist handling
- [`bin/lib/artifact_prep.sh`](../bin/lib/artifact_prep.sh): build/load caching for `rootfs` and `streamImage`
- [`bin/lib/rootfs.sh`](../bin/lib/rootfs.sh): Podman rootfs mirror preparation
- [`bin/lib/container_runtime.sh`](../bin/lib/container_runtime.sh): mount/env assembly and final `podman` or `docker run` args
- [`bin/lib/container_api.sh`](../bin/lib/container_api.sh): isolated Podman session API or raw host socket modes
- [`bin/lib/dev_env.sh`](../bin/lib/dev_env.sh): host direnv snapshotting
- [`bin/lib/need_helper.sh`](../bin/lib/need_helper.sh): narrow host-side Nix helper worker lifecycle
- [`bin/lib/doctor.sh`](../bin/lib/doctor.sh): diagnostics
- [`bin/lib/login.sh`](../bin/lib/login.sh): managed login flow
- [`bin/lib/sessions.sh`](../bin/lib/sessions.sh): session discovery
- [`bin/lib/remote.sh`](../bin/lib/remote.sh): durable remote sandbox lifecycle
- [`bin/lib/init.sh`](../bin/lib/init.sh): project defaults bootstrap

### Nix Definitions

- [`flake.nix`](../flake.nix): flake outputs and script-packaged wrappers
- [`nix/image.nix`](../nix/image.nix): image/rootfs composition, tool launchers, and compatibility shims
- [`nix/detect-packages.nix`](../nix/detect-packages.nix): host project package contract import logic
- [`nix/empty-project`](../nix/empty-project): placeholder project input so flake introspection still evaluates

### Helper Scripts Inside The Image

- [`scripts/image/need.sh`](../scripts/image/need.sh): command lookup, materialization, and injection
- [`scripts/image/agent-compat.sh`](../scripts/image/agent-compat.sh): compatibility wrappers for `sh`, `nix`, and `nix-shell`
- [`bin/agent-direnv-helper`](../bin/agent-direnv-helper): host-side clean direnv snapshot
- [`bin/agent-nix-helper`](../bin/agent-nix-helper): host-side constrained installable materialization service

## Project Contract Resolution

The host project package contract is resolved in this order:
1. `$AGENT_PROJECT_NIX_DIR/packages.nix`
2. `<project-root>/shell.nix`
3. built-in empty project contract

Only contract-related files are staged into the Nix store. This narrows invalidation and avoids exposing the whole repository to the evaluation path.

Staged inputs include:
- top-level `shell.nix`, `default.nix`, `flake.nix`, `flake.lock`
- all files under the selected project `nix/` contract directory
- extra allowlisted paths from `nix/agent-sandbox.paths`
- extra allowlisted paths from `AGENT_PROJECT_CONTRACT_FILES`

For `shell.nix` without `flake.lock`, string-form `fetchTarball` inputs are resolved into project-scoped pins under `AGENT_CACHE_DIR/project-contracts`. Those pins are stable inputs until explicitly removed, so mutable channel URLs do not trigger network checks or package-graph churn during normal startup.

When evaluating `shell.nix`, the detector always injects the resolved `pkgs` package set. This keeps defaults such as `import <nixpkgs> {}` out of pure flake evaluation while preserving them for direct project tooling.

## Artifact Model

The launcher builds one runtime artifact for the selected backend:

- `rootfs`: exploded filesystem used by local Linux Podman through `podman --rootfs`
- `streamImage`: OCI image loaded into Docker via `copyToDockerDaemon`

Cache strategy:
- Nix outputs are persisted as GC roots under `AGENT_CACHE_DIR/gcroots`
- Docker runtime image IDs are cached under `AGENT_CACHE_DIR/images`
- Podman mirror state can be cached under `AGENT_CACHE_DIR/rootfs-cache`

Podman path:
- requires Linux, a local `/nix/store`, and no `CONTAINER_HOST`
- builds `rootfs`
- runs it directly with `podman --rootfs`
- mounts a tiny runtime identity overlay for NSS; when `AGENT_ALLOW_SUDO=1`, the same overlay also provides root-owned setuid sudo under the user namespace

Docker path:
- builds `streamImage`
- loads it with `streamImage.copyToDockerDaemon`
- caches the resolved runtime image ID

## Helper Services

### Direnv Snapshot Helper

When `AGENT_DEV_ENV=host-helper` and `.envrc` exists, the launcher:
- runs a clean host `direnv exec`
- filters out build-system noise and unsupported values
- caches the resulting env file
- injects that snapshot into the container at startup
- orders `PATH` so sandbox guardrail wrappers stay first, then project-local and dev-environment paths, then ambient `need inject` bins and image fallbacks; `AGENT_ALLOW_SUDO=1` inserts `/agent-sudo/bin` immediately after the wrappers
- for `firecracker-host`, adds a `podman` guard wrapper that runs the image's fixed Podman package through `/agent-sudo/bin/sudo -n` with isolated `vfs` and network state under `/cache/agent-firecracker-podman`

There is no live bridge back to host direnv.

### Need Helper

When `AGENT_NEED_HELPER=1`, the launcher starts a narrow host-side worker that:
- accepts only constrained installables
- materializes them in the host store
- returns resulting paths through a mounted request/response bridge
- keeps `need inject` symlinks in a project-scoped bin directory by default

This is the main way the sandbox supports missing tools without exposing the raw Nix daemon socket.

### Podman Session API

When `AGENT_CONTAINER_API=auto` resolves to `podman-session`, or when `AGENT_CONTAINER_API=podman-session` is set explicitly, the launcher:
- starts a dedicated rootless Podman API service
- stores its state under `AGENT_CACHE_DIR`
- mounts only that session socket into the sandbox

This is safer than raw host engine sockets, but it is still a capability bridge.

## Mount And Environment Assembly

The final container typically receives:
- the workspace at the same absolute path, read-write
- Codex always sees the selected home at `/cache/.codex`, preserving the stable absolute rollout paths stored in its thread inventory; project-scoped state is backed by `$PROJECT_ROOT/.codex`, and project launches transactionally rewrite inventory paths left by the former absolute workspace-home layout
- project-scoped Codex settings are stored under `.agent-sandbox/codex` and mounted read-only at `/etc/codex`
- for Codex SSH, `/cache/.ssh` and `/run/host-services` are exposed to Codex's native sandbox with `--add-dir`, avoiding workspace mountpoints
- when the workspace is inside a git repository, the git top-level plus any separate git metadata directories (`--git-common-dir` and `--absolute-git-dir`) needed to make linked worktrees resolve correctly
- `/cache` for tool installs and helper state
- `/nix/store` read-only when present
- selected tool config directories
- optional helper bridges
- optional container API sockets
- optional extra mounts or env passthrough

The final entrypoint is `/bin/<tool>`, backed by the image's Bun-installed tool launcher.

## Tool Wrappers

There are two wrapper layers:

1. Launcher wrappers:
   - `agent <tool>` keeps the underlying tool invocation unchanged
   - `codex`, `claude`, and `opencode` add tool-specific defaults
2. Image wrappers:
   - `need` and compatibility shims provide missing-tool expansion and stable `sh`/Nix behavior

Current shortcut-wrapper defaults:
- `codex`: adds `--yolo`
- `claude`: adds `--dangerously-skip-permissions`
- `opencode`: sets `OPENCODE_PERMISSION=allow` if unset

## File Map By Concern

| Concern | Files |
| --- | --- |
| CLI command parsing | [`bin/agent`](../bin/agent), [`bin/lib/cli.sh`](../bin/lib/cli.sh) |
| runtime and project resolution | [`bin/lib/environment.sh`](../bin/lib/environment.sh) |
| package contract staging | [`bin/lib/project_contract.sh`](../bin/lib/project_contract.sh), [`nix/detect-packages.nix`](../nix/detect-packages.nix) |
| build/load caching | [`bin/lib/artifact_prep.sh`](../bin/lib/artifact_prep.sh), [`bin/lib/rootfs.sh`](../bin/lib/rootfs.sh) |
| container args | [`bin/lib/container_runtime.sh`](../bin/lib/container_runtime.sh) |
| container API | [`bin/lib/container_api.sh`](../bin/lib/container_api.sh) |
| dev env helper | [`bin/lib/dev_env.sh`](../bin/lib/dev_env.sh), [`bin/agent-direnv-helper`](../bin/agent-direnv-helper) |
| narrow Nix helper | [`bin/lib/need_helper.sh`](../bin/lib/need_helper.sh), [`bin/agent-nix-helper`](../bin/agent-nix-helper), [`scripts/image/need.sh`](../scripts/image/need.sh) |
| diagnostics and setup | [`bin/lib/doctor.sh`](../bin/lib/doctor.sh), [`bin/lib/init.sh`](../bin/lib/init.sh), [`bin/lib/login.sh`](../bin/lib/login.sh), [`bin/lib/sessions.sh`](../bin/lib/sessions.sh) |

## Debugging Approach

When behavior is surprising:

1. Run `./scripts/agent doctor`.
2. Run `AGENT_DEBUG=1 ./scripts/agent <tool>`.
3. Check the selected config/auth roots and helper modes.
4. Check whether the selected runtime is using Podman `--rootfs` or Docker `copyToDockerDaemon`.
5. Check whether a helper bridge or raw socket mode widened the boundary.
