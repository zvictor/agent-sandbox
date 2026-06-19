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
2. `.agent-sandbox.env`

Existing environment variables always win over file values.

## High-Impact Knobs

| Variable | Default | Allowed values | Effect |
| --- | --- | --- | --- |
| `AGENT_SANDBOX_PROFILE` | `default` | `default`, `firecracker-host` | Selects the sandbox capability profile |
| `AGENT_RUNTIME` | auto-detect | `podman`, `docker` | Selects the outer runtime |
| `AGENT_CONTAINER_API` | `none` | `none`, `auto`, `podman-session`, `podman-host`, `docker-host` | Controls inner container API exposure |
| `AGENT_DEV_ENV` | `host-helper` | `host-helper`, `none` | Enables or disables the host direnv snapshot helper |
| `AGENT_NEED_HELPER` | `1` | `0`, `1` | Enables or disables the narrow host-backed Nix helper |
| `CODEX_CONFIG` | `host` | `host`, `project`, `fresh`, `<path>` | Selects Codex config root |
| `CLAUDE_CONFIG` | `host` | `host`, `project`, `fresh`, `<path>` | Selects Claude config root |
| `OPENCODE_CONFIG` | `host` | `host`, `project`, `fresh`, `<path>` | Selects OpenCode config root |
| `CODEX_AUTH` | unset | slot name, file path | Overlays Codex credentials |
| `CLAUDE_AUTH` | unset | slot name, file path | Overlays Claude credentials |
| `OPENCODE_AUTH` | unset | slot name, file path | Overlays OpenCode credentials |
| `GIT_ALLOW` | unset | `1` | Disables the sandbox Git guardrail |

## Runtime And Project Resolution

| Variable | Default | Effect |
| --- | --- | --- |
| `AGENT_PROJECT_ROOT` | enclosing git top-level or cwd | Host project root |
| `AGENT_PROJECT_NIX_DIR` | `$AGENT_PROJECT_ROOT/nix` | Project contract directory |
| `AGENT_SANDBOX_FLAKE_REF` | local checkout or `github:zvictor/agent-sandbox` | Sandbox flake source |
| `AGENT_CACHE_DIR` | `$XDG_CACHE_HOME/agent-sandbox` or host-home fallback | Cache root for artifacts, helpers, and tool installs |
| `AGENT_HOST_HOME` | host home fallback | Used for discovering config roots, `.gitconfig`, and auth bases |
| `AGENT_PROJECT_CONTRACT_FILES` | unset | Extra project-relative files or directories staged for package evaluation |

## Runtime Behavior

| Variable | Default | Effect |
| --- | --- | --- |
| `AGENT_FORCE_TTY` | auto | Force `-t` when set to `1` |
| `AGENT_MEMORY_LIMIT` | `4g` | Container memory limit |
| `AGENT_CPU_LIMIT` | `2` | Container CPU limit |
| `AGENT_PIDS_LIMIT` | `512` | Container PID limit |
| `AGENT_WORKSPACE_PATH` | current directory | Workspace mounted at the same absolute path inside the sandbox |
| `AGENT_PODMAN_ROOTFS_MODE` | `auto` | Podman rootfs mode: `auto`, `overlay`, or `mirror` |
| `AGENT_ALLOW_SUDO` | `0` | Enables container-local sudo when set to `1` |
| `AGENT_PERF_LOG` | `1` | Enable or disable timing logs |
| `AGENT_FORCE_REBUILD` | `0` | Rebuild cached runtime artifacts |
| `AGENT_NIX_EXPERIMENTAL_FEATURES` | `nix-command flakes` | Extra Nix experimental features for launcher commands |
| `AGENT_HELPER_TMPDIR` | `$AGENT_CACHE_DIR/tmp` | Temp directory for helper runs |
| `AGENT_DEBUG` | `0` | Print resolved paths and execution details |

### Firecracker Host Profile

Use `AGENT_SANDBOX_PROFILE=firecracker-host` when the agent must run host-level
Firecracker smoke tests from inside the sandbox.

This profile supports one backend: Linux rootful Podman through
`sudo -n podman`. It rejects Docker, remote Podman, rootless Podman, non-Linux
hosts, and explicit container API modes. `AGENT_CONTAINER_API=auto` resolves to
`none` in this profile.

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
- `codex`: host config root to container `~/.codex`
- `opencode`: host config root to container `~/.config/opencode`
- `claude`: host config root to container `~/.claude`
- `omp`: host `~/.omp` to container `~/.omp`
- `codemachine`: mounts Codex, OpenCode, and Claude config roots together

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

When the snapshot includes `PATH`, safety wrappers for `git`, `sh`, `nix`, `nix-shell`, and `need` stay first. Project-local bins and the dev-environment `PATH` come before ambient `need inject` bins and image fallback paths. If `AGENT_ALLOW_SUDO=1`, `/agent-sudo/bin` is inserted immediately after the safety wrappers.

For `.envrc` files that use `use nix` with `<nixpkgs>`, the helper first reuses the current host `NIX_PATH` if present, then falls back to the sandbox flake's locked `nixpkgs` input.

## Nix Helper And Command Expansion

| Variable | Default | Effect |
| --- | --- | --- |
| `AGENT_NEED_HELPER` | `1` | Enables the narrow host-side helper worker |
| `AGENT_NEED_HELPER_TTL` | `900` | Inactivity timeout for the helper |
| `AGENT_NEED_TIMEOUT` | `600` | Request timeout for `need` |
| `AGENT_NEED_BOOTSTRAP_INDEX` | `1` | Starts background `need update-index` when needed |
| `AGENT_NEED_INDEX_URL` | nix-index release URL | Override the downloaded nix-index database |
| `AGENT_NEED_CACHE_DIR` | `$XDG_CACHE_HOME/need` | Cache root for helper materializations |
| `AGENT_NEED_TOOLS_DIR` | project-scoped bin dir under `$XDG_CACHE_HOME/need` | Symlink target dir for `need inject` |
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
| `AGENT_EXTRA_ENV` | unset | Extra `KEY=VALUE` pairs injected into the container |
| `AGENT_AUTO_MOUNT_DIRS` | unset | Auto-mount ancestor directories by name |
| `AGENT_EXTRA_MOUNTS` | unset | Raw mount specs in `host:container[:options]` format |
| `AGENT_EXTRA_DEVICES` | unset | Raw device specs passed through as `--device` |
| `AGENT_PASS_ENV_PREFIXES` | built-in list | Prefixes forwarded from the host environment |

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

The project defaults file accepts plain `KEY=VALUE` lines. Blank lines and `#` comments are ignored. Only sandbox-related keys are loaded, such as:
- `AGENT_*`
- `CODEX_*`
- `CLAUDE_*`
- `OPENCODE_*`
- `OMP_*`
- `PI_*`
- `TESTCONTAINERS_*`
- `GIT_ALLOW`

Example:

```sh
AGENT_CONTAINER_API=auto
AGENT_NEED_HELPER=1
CODEX_CONFIG=project
CODEX_AUTH=work
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
