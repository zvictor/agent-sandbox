# Agent Sandbox

Reusable sandbox runtime for coding agents.

Supported tools:
- `codex`
- `claude`
- `opencode`
- `codemachine`
- `omp` (`oh-my-pi`)

# What is Agent Sandbox

`agent-sandbox` is a Nix-based containerized runtime system that executes AI coding agents (such as Codex, Claude Code, OpenCode, CodeMachine, and OMP) inside isolated container environments. It integrates with host project dependencies through Nix package contracts while maintaining safety boundaries between the agent and the host system.

The system provides two runtime artifacts, selected by backend:

* `rootfs`: an exploded filesystem used by local Linux Podman through `podman --rootfs`
* `streamImage`: an OCI image loaded into Docker via `copyToDockerDaemon`

And multiple user-facing entry points:

* **CLI wrapper**: `bin/agent` dispatcher that handles commands like `init`, `doctor`, `login`, `sessions`, and `run`
* **Tool-specific shortcuts**: Direct executables for `codex`, `claude`, `opencode`, `codemachine`, and `omp`
* **Nix flake packages**: Installable via `nix run github:zvictor/agent-sandbox#<tool>`

# Why agent-sandbox exists

AI coding agents need access to development tools, project dependencies, and the workspace to function effectively. However, running them directly on the host exposes the entire system to potential mistakes or unintended side effects from agent-generated code. Traditional approaches face a dilemma: either sacrifice safety for functionality or sacrifice functionality for safety.

agent-sandbox resolves this tension by:

* **Isolating execution context**: Agents run inside containers with a narrow capability set, resource limits, and explicit filesystem mounts rather than ambient host access
* **Preserving workspace access**: The project directory is mounted at its real path, allowing agents to work naturally while limiting scope
* **Integrating project dependencies**: Nix contracts (`nix/packages.nix` or `shell.nix`) make host project tooling available inside the container without manual duplication
Centralizing safety defaults**: Tool-specific wrappers apply consistent safety settings (e.g., `codex --yolo`, `claude --dangerously-skip-permissions`) so the container boundary becomes the primary protection layer
* **Supporting container workflows**: Optional container API access (via `podman-session` or raw sockets) enables Testcontainers and development workflows that agents might need

The result is a practical middle ground: stronger isolation than running agents directly on the host, while remaining more functional than fully sealed sandboxes that break agent workflows.

## Quick Start

For a new project:

```sh
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#agent -- init
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#agent -- doctor
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#agent -- login codex work
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#agent -- login codex work --config project
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#agent -- sessions codex
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#viewer
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#agent -- run codex
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#codex
```

From a local checkout:

```sh
./scripts/agent init
./scripts/agent doctor
./scripts/agent login codex work
./scripts/agent login codex work --config project
./scripts/agent sessions codex
./scripts/viewer
./scripts/agent run codex
./scripts/codex
```

## Runtime Model

The runtime paths are intentionally minimal.

- `podman` uses the local Linux `--rootfs` fast path
  - default: `--rootfs ...:O`
  - `rootless-linux` always uses a cached local writable rootfs mirror with an ephemeral `:O` upper layer so unmapped container root is not needed to create mount targets
  - on rootless native overlay hosts that break `:O`, the launcher uses a cached local writable rootfs mirror and still runs `podman --rootfs ...:O`
- `docker` uses one path only: build `streamImage`, then load it with `streamImage.copyToDockerDaemon`

There is no compatibility matrix beyond that.

Practical consequences:
- Podman requires Linux, a local `/nix/store`, and no `CONTAINER_HOST`.
- Docker is the fallback path when Podman is not available.
- if the selected runtime does not satisfy its requirements, the launcher fails fast

For a generic delegated rootless-Linux environment, use:

```sh
AGENT_SANDBOX_PROFILE=rootless-linux ./scripts/codex
```

This profile requires a pre-existing host `systemd --user` manager, an owned
`XDG_RUNTIME_DIR`, cgroup-v2 CPU/memory/PID delegation, unprivileged user
namespaces, and rootless Podman. The launcher enters a delegated host user
scope, gives the container a private cgroup namespace, and starts a private
container-local user manager. It never mounts the host user bus into the
container. The agent stays unprivileged with no effective capabilities, and
the profile rejects Docker, remote-container mode, root, and
`AGENT_ALLOW_SUDO=1`. It also rejects caller-supplied mounts/devices, container
API exposure, KVM, and Nix daemon access. The image provides Bubblewrap 0.12.0
and verifies the manager, delegated controls, and a nested rootless Bubblewrap
invocation before starting the agent. A missing predicate is a hard
unsupported-host error.

For Firecracker host smoke tests, use the explicit host-control profile:

```sh
AGENT_SANDBOX_PROFILE=firecracker-host ./scripts/codex
```

That profile supports only Linux rootful Podman through `sudo -n podman`.
It preflights KVM, `/dev/net/tun`, writable cgroup v2, root workspace
write/chown, and non-interactive sudo before launch. The container runs
privileged with host user, cgroup, and network namespaces while the agent
process stays on the host UID/GID and has `CAP_NET_ADMIN` for tap setup;
other privileged Firecracker operations go through in-container `sudo`. Inside
this profile, the sandbox PATH maps
`podman` to rootful Podman with an isolated `vfs` store at
`/cache/agent-firecracker-podman` and managed network definitions under that
same state directory, so local OCI image build/run validation does not depend
on rootless `/etc/subuid` or `/etc/subgid` mappings, nested overlay support, or
mutable `/etc/containers` state. Run the launcher itself as the operator user;
`sudo ./scripts/codex` is rejected because it changes host auth/config and
cache ownership semantics.

For host-side process observers, the runtime is launched under a supervisor
whose `argv[0]` is the selected logical tool name. Observers that inspect the
foreground job can see `codex`, `claude`, `opencode`, and similar names even
though the container still runs through Podman or Docker internally.

## Host Project Contract

The launcher looks for the host project's package contract in this order:
1. `$AGENT_PROJECT_NIX_DIR/packages.nix`
2. `<project-root>/shell.nix`
3. built-in empty project contract

Default `AGENT_PROJECT_NIX_DIR` is `<project-root>/nix`.

### Recommended: `nix/packages.nix`

```nix
{ pkgs, unstable }:
[
  pkgs.bun
  pkgs.git
  pkgs.nodejs
]
```

You may also return an attrset with `devPackages`:

```nix
{ pkgs, unstable }:
{
  devPackages = [
    pkgs.bun
    pkgs.git
  ];
}
```

### Fallback: `shell.nix`

If `nix/packages.nix` is absent, the launcher falls back to `shell.nix` and extracts packages from:
- `buildInputs`
- `nativeBuildInputs`
- `packages`

Example:

```nix
{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  packages = [
    pkgs.bun
    pkgs.git
    pkgs.nodejs
  ];
}
```

The launcher always supplies `pkgs` when it evaluates this contract. Defaults such as `import <nixpkgs> {}` remain useful for direct `nix-shell` and direnv use, but are not evaluated by the sandbox's pure flake build.

Use `nix/packages.nix` if your `shell.nix` is complex or relies on evaluation patterns that do not import cleanly.

### No Nix files present

If neither `nix/packages.nix` nor `shell.nix` exists, the launcher still starts the sandbox.

- the built-in base sandbox environment is used
- no extra project-specific dev packages are added
- the workspace is still mounted normally

### Invalidation scope

When the launcher stages project package inputs for Nix evaluation, it copies only contract-related files:

- top-level `shell.nix`, `default.nix`, `flake.nix`, `flake.lock`
- files under the selected project `nix/` contract directory
- extra project files listed in `nix/agent-sandbox.paths`
- extra project files listed in `AGENT_PROJECT_CONTRACT_FILES`

Changes outside that set do not invalidate the sandbox package input.

When `shell.nix` uses the string form `fetchTarball "..."` and no `flake.lock` is present, the launcher resolves it once and stores a project-scoped pin under `AGENT_CACHE_DIR/project-contracts`. The unpacked store path is retained under a host GC root, so later starts reuse that pin without checking the URL, including mutable Nix channel URLs. The startup log prints the exact pin path; remove that file when you want to update the tarball.

If your Nix contract depends on files outside the selected `nix/` directory, list them explicitly in `nix/agent-sandbox.paths`:

```text
package.json
tool-versions.json
config/versions.lock
```

Rules:
- paths are relative to the project root
- blank lines and `#` comments are ignored
- `..` and absolute paths are rejected
- directories are allowed, but they widen invalidation to that entire subtree

## Project Defaults

Instead of exporting a long list of environment variables before every run, you can define project-level sandbox defaults in a file. The launcher checks these locations in order:

1. `AGENT_PROJECT_CONFIG_FILE`
2. `.agent-sandbox.env`

The format is `KEY=VALUE` assignments, with quoted values allowed to span multiple lines. Blank lines and `#` comments outside quoted values are ignored. Existing environment variables still take precedence over file values.

Example:

```sh
AGENT_CONTAINER_API=auto
AGENT_NEED_HELPER=1
CODEX_CONFIG=project
CODEX_AUTH=work
```

Only sandbox-related keys are loaded from the file, such as `AGENT_*`, tool auth/config keys, and `TESTCONTAINERS_*`.

Use a quoted `AGENT_EXTRA_ENV` block to inject several container variables:

```dotenv
AGENT_EXTRA_ENV="
    TMPDIR=$PWD/.tmp
    OPENROUTER_API_KEY=<OPENROUTER_KEY>
    MISTRAL_API_KEY=<MISTRAL_KEY>
"
```

Each nonblank line is one `KEY=VALUE`; indentation before the key is ignored. `$VAR` and `${VAR}` references expand from the launcher's environment. The file is data, not a shell script: command substitution such as `$(cat <<EOF ...)` is rejected. Keep files containing credentials out of version control. See [the configuration reference](docs/CONFIG.md#project-defaults-file) for quoting and validation rules.

Bootstrap the file with:

```sh
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#agent -- init
./scripts/agent init
```

Useful variants:

- `agent init --force`: overwrite an existing defaults file
- `agent init --stdout`: print the template instead of writing it

`agent init` now suggests named credential slots like `CODEX_AUTH=work` instead of the older profile convention.

`agent codex` can use Codex's native Bubblewrap sandbox inside the outer container because the image provides upstream Bubblewrap 0.12.0 at `/usr/bin/bwrap`.

For SSH operations under Codex's native sandbox, the launcher exposes the sandbox SSH runtime paths to Codex with `--add-dir` rather than creating a temporary mountpoint inside the workspace.

## Common Recipes

- Safest default: use `agent <tool>` instead of the shortcut wrapper if you want the tool's native safety prompts left on.
- Fastest Codex workflow: run `./scripts/codex` after `./scripts/agent init`.
- Session viewer: run `./scripts/viewer` or `agent viewer` to start Claude Code History Viewer server mode on `127.0.0.1:3727`; the launcher prints the authenticated URL.
- Remote sandbox: run `./scripts/agent remote up` from a worktree, then `./scripts/agent remote codex` to use a durable tmux-backed Codex session that can also be reached from a phone over Tailscale/SSH. See [docs/REMOTE.md](docs/REMOTE.md).
- Project-scoped state: set `CODEX_CONFIG=project`, `CLAUDE_CONFIG=project`, or `OPENCODE_CONFIG=project`.
- Ephemeral run: set `<TOOL>_CONFIG=fresh`.
- Project-local login: `./scripts/agent login codex work --config project`.
- Missing command: run `need <command>` or `need run <command> -- <command> ...`.
- SSH Git remotes: the sandbox now synthesizes a read-only `/cache/.ssh` from host SSH client state and forwards the active host agent to `/run/host-services/ssh-auth.sock` when `SSH_AUTH_SOCK` is set.
- SSH `ProxyCommand` helpers: if your SSH config calls tools like `cloudflared`, add them to the sandbox package contract so they exist inside the container too.

More complete workflows live in [docs/RECIPES.md](docs/RECIPES.md).

## Guarantees And Non-Goals

You can rely on these behaviors:
- The selected workspace is mounted read-write at the same absolute path inside the sandbox.
- Tool config mounts are explicit rather than ambient.
- The standard Git executable is available, including commands that update the index, refs, and repository configuration.
- Container-local `sudo` is disabled by default and is enabled only with `AGENT_ALLOW_SUDO=1`.
- Every supported container runs an engine-managed init as PID 1; agent tools and remote services are its children, so orphaned descendants are reaped.
- `agent doctor` uses the same runtime resolution rules as real execution.
- Podman runs the rootfs artifact directly; Docker runs the OCI image artifact.

You should not rely on these behaviors:
- Strong protection against workspace writes.
- A network-denied environment.
- Credential isolation once a writable config directory is mounted.
- Raw Docker, Podman, or Nix daemon sockets being safe capability boundaries.

The full threat model is in [docs/SANDBOX-SAFETY.md](docs/SANDBOX-SAFETY.md).

## Runtime Model

The runtime paths are intentionally narrow:
- `podman` uses the local Linux `--rootfs` fast path.
- The `rootless-linux` profile always uses a cached local writable rootfs mirror with an ephemeral `:O` upper layer so unmapped container root is not needed to create mount targets.
- On rootless native overlay hosts that break `:O`, the launcher uses a cached local writable rootfs mirror and still runs Podman `--rootfs ...:O`.
- `docker` uses one path only: build `streamImage`, then load it with `streamImage.copyToDockerDaemon`.

Practical consequences:
- Podman requires Linux, a local `/nix/store`, and no `CONTAINER_HOST`.
- Docker is the fallback when Podman is not available.
- Podman and Docker must support `run --init`; launch fails instead of running an agent or service directly as PID 1.
- If the selected runtime does not satisfy its requirements, the launcher fails fast.

For the implementation flow and file map, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Installation

### NixOS or any flake-based host

Add the sandbox as a flake input and install `agent` or the tool-specific wrappers.

```nix
{
  inputs.agent-sandbox.url = "github:zvictor/agent-sandbox";

  outputs = { self, nixpkgs, agent-sandbox, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          agent-sandbox.packages.${system}.agent
        ];
      };
    };
}
```

Tool-specific wrappers are also available:

```nix
agent-sandbox.packages.${system}.codex
agent-sandbox.packages.${system}.claude
agent-sandbox.packages.${system}.opencode
agent-sandbox.packages.${system}.codemachine
agent-sandbox.packages.${system}.omp
```

These shortcut wrappers apply tool-specific defaults where supported:

- `codex` adds `--yolo`
- `claude` adds `--dangerously-skip-permissions`
- `opencode` sets `OPENCODE_PERMISSION=allow` if it is unset

Use `agent` if you want the underlying tool invocation without those wrapper defaults.

### One-off run

```sh
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#agent -- codex
```

Shortcut form with implicit Codex yolo mode:

```sh
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#codex
```

Local checkout:

```sh
AGENT_PROJECT_ROOT="$PWD" nix run path:/path/to/agent-sandbox#agent -- codex
```

Shortcut form with implicit Codex yolo mode:

```sh
AGENT_PROJECT_ROOT="$PWD" nix run path:/path/to/agent-sandbox#codex
```

### Direct script usage from this repo

```sh
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/agent codex
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/agent run codex
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/agent login codex work
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/agent login codex work --config project
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/agent sessions codex
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/agent init
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/agent doctor
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/codex
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/claude
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/opencode
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/codemachine
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/omp
```

The tool-specific scripts apply the same per-tool defaults as the flake shortcuts; `./scripts/agent <tool>` remains unchanged.

### Diagnostics

Use `agent doctor` to inspect the resolved sandbox state without starting a container:

```sh
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#agent -- doctor
./scripts/agent doctor
./scripts/agent doctor --verbose
./scripts/agent doctor --json
```

By default it prints a short summary plus suggested fixes, including the effective enabled tool surface for the current project and whether the project root came from `AGENT_PROJECT_ROOT`, the enclosing git repo, or the current directory. Use `--verbose` for the full state dump and `--json` for machine-readable output.

### Visible sessions

Use `agent sessions codex` to list the Codex sessions visible through the current `CODEX_CONFIG` selection:

```sh
./scripts/agent sessions codex
./scripts/agent sessions codex --all
./scripts/agent sessions codex --json
```

This is the fastest way to confirm what `codex resume <session>` will be able to see:

- `CODEX_CONFIG=host`: all sessions in the host `~/.codex`
- `CODEX_CONFIG=project`: only sessions stored under `$PROJECT_ROOT/.codex/sessions`
- `CODEX_CONFIG=fresh`: no prior sessions are visible
- `CODEX_CONFIG=/path/to/.codex`: sessions from that exact config root

For `CODEX_CONFIG=project`, `agent sessions codex` treats the project session root as the scope and lists all sessions stored there.

## Tool Configuration Mounts

The launcher mounts tool config directories into the container at the tools' normal home-relative locations. In `CODEX_CONFIG=project` mode, the host user's `~/.codex` is mounted as the Codex home at `/cache/.codex`, while the repository's `.codex` remains visible at its normal workspace path as the project configuration layer. The launcher overlays `$PROJECT_ROOT/.codex/sessions` at `/cache/.codex/sessions` and points `CODEX_SQLITE_HOME` at the project `.codex`, so transcripts and their resume inventory keep project-local host paths without making the entire project `.codex` directory double as the user home. This means a user hook belongs in host `~/.codex/hooks.json`, a project hook belongs in `$PROJECT_ROOT/.codex/hooks.json`, and Codex discovers each layer once. Project hooks run only after the project is trusted. A launcher-managed settings layer lives in `.agent-sandbox/codex/managed_config.toml` and is mounted read-only at `/etc/codex`; on first use it is seeded from the temporary cache-backed project config, an existing project config, or the host config, in that order. Project launches also repair thread-inventory paths written by the short-lived absolute workspace-home layout, allowing those sessions to be forked as well as resumed.

The project `.codex` can be a directory symlink, for example `main/.codex -> ../.codex` to share config and sessions across checkouts. The launcher mounts the target directory as needed, preserves the symlink, and keeps sessions at `$PROJECT_ROOT/.codex/sessions`. The project and user config directories must resolve to different directories. See [Tool Config Roots And Auth](docs/CONFIG.md#tool-config-roots-and-auth) for validation rules.

- `codex`: selected host config root to `/cache/.codex`
- `opencode`: host config root to container `~/.config/opencode`
- `claude`: host config root to container `~/.claude`
- `omp`: host `~/.omp` to container `~/.omp`
- `codemachine`: mounts Codex, OpenCode, and Claude config roots together

Tool-specific auth selection:
- `CODEX_AUTH=work` overlays `~/.local/share/agent-sandbox/auth/codex/work.json` as `auth.json`
- `CODEX_AUTH=/path/to/auth.json` overlays that exact file as `auth.json`
- `CLAUDE_AUTH` and `OPENCODE_AUTH` follow the same `name-or-path` model for their credential files

Tool-specific config selection:
- `CODEX_CONFIG=host`: use the host default `~/.codex`
- `CODEX_CONFIG=project`: use host `~/.codex` as the user layer, keep `$PROJECT_ROOT/.codex` as the project layer, and store sessions at `$PROJECT_ROOT/.codex/sessions`
- `CODEX_CONFIG=fresh`: create a clean temporary config dir for this run
- `CODEX_CONFIG=/path/to/.codex`: use that exact host directory
- `CLAUDE_CONFIG` and `OPENCODE_CONFIG` follow the same `host|project|fresh|<path>` model

The first project-mode run imports non-conflicting sessions, archived sessions, history, and SQLite state from the temporary cache-backed implementation. The old cache directory is preserved for recovery and is no longer an active Codex home.

Create a fresh named Codex login with:

```sh
./scripts/agent login codex work
./scripts/agent login codex work --config project
```

Then confirm the visible session scope with:

```sh
./scripts/agent sessions codex
```

For `omp`, the launcher mounts the whole `~/.omp` tree. It does not implement a separate credential overlay layer.

## Security and Behavior

For a fuller threat model and a comparison with each supported agent's native safety model, see [docs/SANDBOX-SAFETY.md](docs/SANDBOX-SAFETY.md).

### Git inside the sandbox

The sandbox provides the standard Git executable without a command allowlist. Commands such as `add`, `commit`, `branch`, `config`, and `reset` run normally against the read-write workspace.

### Agent package installation

The agent CLIs themselves are installed lazily with Bun into per-tool cache directories under `/cache/<tool>`.

This means:
- first run may install or update the tool package
- subsequent runs reuse the cached tool installation
- the image stays smaller than baking all agent npm packages directly into the root filesystem

By default, Codex tracks the latest `@openai/codex` package. To start a
session with a specific Codex CLI package version, set `AGENT_CODEX_VERSION`:

```sh
AGENT_CODEX_VERSION=0.141.0 ./scripts/codex resume <session-id>
```

Unset `AGENT_CODEX_VERSION`, or set it to `latest`, to use the normal
auto-update behavior.

## Performance Model

The launcher is optimized around two caches:
- reusable Nix artifacts are rooted under `AGENT_CACHE_DIR/gcroots`, while each running sandbox also owns a separate lifetime lease
- installed Bun tool packages live under `AGENT_CACHE_DIR/tools/<tool>`

Warm-path behavior is typically:
- project package contract is added to the store
- existing `rootfs` or `streamImage` derivation is reused
- cached tool package is reused

Performance logs are enabled by default.

Disable them with:

```sh
AGENT_PERF_LOG=0
```

Force rebuilding the Nix artifact with:

```sh
AGENT_FORCE_REBUILD=1
```

## Environment Variables

### Primary Launcher Knobs

- `AGENT_PROJECT_ROOT`: host project root; defaults to current git top-level or cwd
- `AGENT_PROJECT_NIX_DIR`: package contract directory; defaults to `$AGENT_PROJECT_ROOT/nix`
- `AGENT_SANDBOX_FLAKE_REF`: override sandbox flake source
- `AGENT_RUNTIME`: `podman` or `docker`; defaults to auto-detect
- `AGENT_CACHE_DIR`: cache directory for GC roots, runtime leases, tool installs, and helper bridge files
- `AGENT_HOST_HOME`: host home used for discovering `~/.codex`, `~/.claude`, `~/.omp`, `.gitconfig`, and similar paths

### Build, Cache, and Logs

- `AGENT_FORCE_REBUILD=1`: discard cached runtime artifacts and rebuild them
- `AGENT_PERF_LOG=0|1`: disable or enable timing logs; default `1`
- `AGENT_NIX_EXPERIMENTAL_FEATURES`: override extra Nix experimental features; default `nix-command flakes`
- `AGENT_HELPER_TMPDIR`: temp directory for helper runs
- `AGENT_PROJECT_CONTRACT_FILES`: extra project-relative files or directories to stage for package evaluation

### Runtime behavior

- `AGENT_FORCE_TTY=1`: force `-t`
- `AGENT_MEMORY_LIMIT`: container memory limit; default `4g`
- `AGENT_CPU_LIMIT`: container CPU limit; default `2`
- `AGENT_PIDS_LIMIT`: container PID limit; default `512`
- `AGENT_WORKSPACE_PATH`: workspace directory mounted at the same absolute path inside the sandbox; defaults to current directory
- `AGENT_PODMAN_ROOTFS_MODE`: `auto`, `overlay`, or `mirror`; default `auto`; `rootless-linux` requires `auto` or `mirror` and always selects the mirror
- `AGENT_DEV_ENV`: `host-helper` or `none`; default `host-helper`
- `AGENT_ALLOW_SUDO`: set to `1` to enable container-local sudo; default `0`

With `AGENT_DEV_ENV=host-helper`, the launcher resolves a clean host `direnv` environment snapshot for the project root before the container starts, caches the filtered result under `AGENT_CACHE_DIR`, and passes that environment into the sandbox at startup. There is no live host `direnv` bridge in the running container; if `.envrc` changes, restart the sandbox session to refresh the injected environment.

When a dev environment exports `PATH`, the sandbox keeps its base commands and compatibility wrappers (`git`, `sh`, `nix`, `nix-shell`, and `need`) first, then project-local paths and the dev-environment `PATH` before ambient `need inject` tools and image fallback paths. If `AGENT_ALLOW_SUDO=1`, `/agent-sudo/bin` is inserted immediately after those base commands. This prevents stale injected tools from shadowing the project's Nix shell while preserving the sandbox runtime behavior.

For `.envrc` files that use `use nix` with `<nixpkgs>`, the helper first reuses the current host `NIX_PATH` if present, then falls back to the sandbox flake's locked `nixpkgs` input. If you need to force a specific `nixpkgs` tree for host-helper resolution, set `AGENT_DIRENV_NIX_PATH=/path/to/nixpkgs`.

### Nix binary cache inside container

- `AGENT_USE_LOCAL_BINCACHE=1|0`: enable or disable `file:///nixcache`; default `1`
- `AGENT_NIX_BINCACHE_DIR`: host directory mounted read-only at `/nixcache`
- `AGENT_LOCAL_BINCACHE_ALLOW_UNSIGNED=1`: allow unsigned local substitutes

### Container API access

- `AGENT_CONTAINER_API`: `none`, `auto`, `podman-session`, `podman-host`, or `docker-host`; default `none`
- `AGENT_CONTAINER_API_TTL`: inactivity timeout in seconds for `podman-session`; default `900`
- `AGENT_CONTAINER_API_WAIT_SECONDS`: socket readiness timeout for `podman-session`; default `30`
- `AGENT_CONTAINER_API_RESET=1`: discard the cached `podman-session` state directory before starting it again

Recommended for Testcontainers:

- `AGENT_CONTAINER_API=auto`

In `podman-session` mode, the launcher starts a dedicated rootless Podman API service, stores its state under `AGENT_CACHE_DIR`, waits for the session socket to become ready, and mounts only that session socket into the agent container.

In `auto` mode, the launcher chooses `podman-session` when host Podman is available and usable, otherwise it falls back to `none`.

### Raw host socket compatibility opts

- `AGENT_ALLOW_NIX_DAEMON_SOCKET=1`: mount the host Nix daemon socket into the container
- `AGENT_ALLOW_PODMAN_SOCKET=1`: compatibility alias for `AGENT_CONTAINER_API=podman-host`
- `AGENT_ALLOW_DOCKER_SOCKET=1`: compatibility alias for `AGENT_CONTAINER_API=docker-host`

These are disabled by default because they significantly widen the sandbox boundary.

For full generic `nix-shell` and `nix shell` workflows inside the sandbox, the launcher still prepares the writable profile and gcroot directories under `/cache`, but materializing packages that are not already present in the mounted store still requires `AGENT_ALLOW_NIX_DAEMON_SOCKET=1`.

Full flake builds such as `nix build .#streamImage` and `nix develop` also require either running on the host or starting the sandbox with `AGENT_ALLOW_NIX_DAEMON_SOCKET=1`. Without the daemon socket, the container only has a read-only `/nix` mount and local Nix fails when it tries to create `/nix/var/nix/temproots`.

For the common “give me a tool and run it” cases, the sandbox now intercepts the narrow subset automatically:

```sh
nix shell nixpkgs#podman --command podman --version
nix-shell -p podman --run 'podman --version'
podman --version
docker version
```

Those paths use the host-backed Nix helper when possible, so the agent can keep using normal commands instead of learning sandbox-specific ones.

### Host Nix tool helper

- `AGENT_NEED_HELPER=1|0`: enable or disable the narrow host-side need helper; default `1`
- `AGENT_NEED_TIMEOUT`: request timeout in seconds for `need`; default `600`
- `AGENT_NEED_BOOTSTRAP_INDEX=1|0`: automatically start a background `need update-index` on first shell startup when the local command index is missing; default `1`

When enabled, the launcher starts a small host-side helper worker in the background and mounts a request/response bridge into the sandbox. The raw Nix daemon socket remains unavailable unless `AGENT_ALLOW_NIX_DAEMON_SOCKET=1` is explicitly set. Inside the sandbox, use:

```sh
need update-index
need podman
need run podman -- podman --version
need inject pnpm
need clear
need clear --all
```

The helper is intentionally narrow. It only materializes constrained installables such as `nixpkgs#<attr>` and selected `github:NixOS/nixpkgs/...#<attr>` refs. Every output is rooted by a host-owned runtime lease before it is returned. Foreground Podman leases follow the generated container identity, so launcher exit cannot release them before confirmed container teardown. The root directory is not mounted into the sandbox. Instead, the sandbox receives `/run/agent-runtime-receipts` as a read-only mount containing the lease identity, output paths, and complete closure identities. Bare `need <command>` lookups use `nixos-unstable` by default; use `nixpkgs#...` when you explicitly want the stable channel.

The enabled helper and its lease outlive inner coordinator restarts. The helper remains available until the foreground sandbox exits or `agent remote down` removes a remote lease. A detached host guard removes foreground leases after confirmed container teardown; the next launch prunes any remaining lease only when both its launcher and bound container are gone.

`need inject` writes lease-checking command launchers to a project-scoped bin directory by default, so an injected tool in one checkout does not shadow another project's shell or bypass admission in a later sandbox. `need clear` removes the current project's injected launchers, `need clear --legacy` removes the old shared injected bin directory, and `need clear --all` removes the whole `need` cache for the current tool cache. These cache operations do not expose or mutate host lease roots.

If the nix command index is missing, the sandbox now starts downloading it in the background when the agent boots. That bootstrap is non-blocking, so the first interaction still runs immediately; `need update-index` remains available as the explicit refresh command.

### Seamless command shims

The image now prefers compatibility shims over sandbox-specific instructions:

- `nix shell <installable> --command ...` is rewritten to the narrow helper path when the invocation is simple enough
- `nix-shell -p <pkg> --run ...` and `nix-shell -p <pkg> -- ...` are rewritten the same way
- agent-style `/bin/sh -c` and `/bin/sh -lc` commands now print `need` guidance after a real `command not found` failure instead of retrying transparently
- `need` uses `nix-locate` when the local nix-index database is available, and falls back to transparent best-effort guesses otherwise

The `need` command is the main escape hatch for missing tools:

```sh
need update-index
need pnpm
need run pnpm -- pnpm -v
need inject pnpm
need clear
```

### Mounts and environment passthrough

- `AGENT_EXTRA_ENV`: extra `KEY=VALUE` pairs injected into the container
- `AGENT_AUTO_MOUNT_DIRS`: comma- or newline-separated directory names to auto-mount from ancestor directories
- `AGENT_EXTRA_MOUNTS`: extra raw mount specs in `host:container[:options]` format
- `AGENT_EXTRA_DEVICES`: comma- or newline-separated device specs passed as `--device`
- `AGENT_PASS_ENV_PREFIXES`: comma- or newline-separated environment variable prefixes to forward

For nested VM workloads on hosts that expose KVM, prefer explicit device passthrough instead of relying on TCG fallback:

```sh
AGENT_ALLOW_KVM=1 ./scripts/codex
AGENT_EXTRA_DEVICES=/dev/kvm ./scripts/codex
```

### Tool config overrides

- `CODEX_CONFIG`: `host`, `project`, `fresh`, or an explicit host directory path
- `AGENT_CODEX_VERSION`: exact `@openai/codex` package version for the sandboxed Codex launcher; unset or `latest` keeps auto-update behavior
- `OPENCODE_CONFIG`: `host`, `project`, `fresh`, or an explicit host directory path
- `CLAUDE_CONFIG`: `host`, `project`, `fresh`, or an explicit host directory path
- `CODEX_AUTH`: named managed slot like `work` or an explicit credential file path
- `OPENCODE_AUTH`: named managed slot like `work` or an explicit credential file path
- `CLAUDE_AUTH`: named managed slot like `work` or an explicit credential file path
- `AGENT_AUTH_HOME`: base directory for managed credential slots; defaults to `~/.local/share/agent-sandbox/auth`
- `CODEX_AUTH_BASE_DIR`: override the managed Codex auth slot directory
- `OPENCODE_AUTH_BASE_DIR`: override the managed OpenCode auth slot directory
- `CLAUDE_AUTH_BASE_DIR`: override the managed Claude auth slot directory
- `PI_CODING_AGENT_DIR`: host oh-my-pi agent directory; defaults to `~/.omp/agent`

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

### Debugging

- `AGENT_DEBUG=1`: print resolved paths, selected runtime, and final execution details

### Compatibility Aliases

These are still accepted by the launcher, but they are not the preferred interface:

- `AGENT_SANDBOX_FLAKE`: compatibility alias for `AGENT_SANDBOX_FLAKE_REF`
- `CODEX_RUNTIME`: compatibility alias for `AGENT_RUNTIME`
- `OMP_CODING_AGENT_DIR`: compatibility alias for `PI_CODING_AGENT_DIR`
- `AGENT_ALLOW_PODMAN_SOCKET=1`: compatibility alias for `AGENT_CONTAINER_API=podman-host`
- `AGENT_ALLOW_DOCKER_SOCKET=1`: compatibility alias for `AGENT_CONTAINER_API=docker-host`
- `AGENT_ALLOW_KVM=1`: compatibility alias for `AGENT_EXTRA_DEVICES=/dev/kvm`

## Ambient Host Environment

The launcher also reacts to a few standard host environment variables. These are not treated as part of the primary sandbox API:

- `CONTAINER_HOST`: if set, Podman mode is rejected because local `podman --rootfs` execution is required
- `XDG_RUNTIME_DIR`: used to locate the rootless Podman socket when `AGENT_CONTAINER_API=podman-host`
- `XDG_CACHE_HOME`: used as the default base for `AGENT_CACHE_DIR`
- `TMPDIR`: used for helper temp files when `AGENT_HELPER_TMPDIR` is unset

## Reference Docs

- [docs/CONFIG.md](docs/CONFIG.md): environment variables, config roots, auth selectors, and compatibility aliases
- [docs/RECIPES.md](docs/RECIPES.md): opinionated task-oriented workflows
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): launcher flow, runtime artifacts, helpers, and file map
- [docs/SANDBOX-SAFETY.md](docs/SANDBOX-SAFETY.md): threat model, guarantees, and safety comparison

## Low-Level Flake Outputs

These outputs are intended for debugging or integration work, not normal interactive use.

- `.#rootfs`: exploded filesystem artifact used by the Podman runtime path
- `.#streamImage`: OCI image derivation used by the Docker runtime path

Examples:

```sh
# Run these on the host, or inside a sandbox started with
# AGENT_ALLOW_NIX_DAEMON_SOCKET=1.
nix build .#rootfs
nix build .#streamImage
```

## Version and Introspection

Print the sandbox revision:

```sh
./scripts/agent --version
```

Show flake outputs:

```sh
nix flake show path:.
```

Run the fast regression suite and the live Podman/rootfs PID-1 test:

```sh
bash tests/regression.sh
# Run from the host or a firecracker-host sandbox with Podman available.
AGENT_RUN_PID1_REAPER_TESTS=1 bash tests/regression.sh
```

The live test repeatedly orphans descendants and requires the zombie count to
return to its baseline after every cycle. The default sandbox intentionally
does not expose nested Podman, so use the fast suite there.

## Release

```sh
nix --extra-experimental-features 'nix-command flakes' flake show path:.
nix --extra-experimental-features 'nix-command flakes' flake update
```
