# Agent Sandbox

Reusable sandbox runtime for coding agents.

Supported tools:
- `codex`
- `claude`
- `opencode`
- `codemachine`
- `omp` (`oh-my-pi`)

## What This Repo Does

This repo builds and runs agent sandboxes against a host project's Nix package contract.

It exposes two low-level artifacts:
- `rootfs`: exploded filesystem used by the Podman fast path
- `streamImage`: OCI image used by the Docker path via `copyToDockerDaemon`

It also exposes runnable wrappers:
- flake packages: `agent`, `codex`, `claude`, `opencode`, `codemachine`, `omp`
- flake apps: `#agent`, `#codex`, `#claude`, `#opencode`, `#codemachine`, `#omp`
- scripts: `./scripts/agent`, `./scripts/codex`, `./scripts/claude`, `./scripts/opencode`, `./scripts/codemachine`, `./scripts/omp`

## Runtime Model

The runtime paths are intentionally minimal.

- `podman` uses the local Linux `--rootfs` fast path
- default: `--rootfs ...:O`
  - on rootless native overlay hosts that break `:O`, the launcher falls back to a cached local writable rootfs mirror and still uses `--rootfs ...:O`
- `docker` uses one path only: build `streamImage`, then load it with `streamImage.copyToDockerDaemon`

There is no compatibility matrix beyond that.

Practical consequences:
- Podman requires Linux, a local `/nix/store`, and no `CONTAINER_HOST`
- Docker is the fallback path for non-Linux hosts or hosts that do not meet the Podman requirements
- if the selected runtime does not satisfy its requirements, the launcher fails fast

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

Use `nix/packages.nix` if your `shell.nix` is complex or relies on evaluation patterns that do not import cleanly.

### No Nix files present

If neither `nix/packages.nix` nor `shell.nix` exists, the launcher still starts the sandbox.

- the built-in base sandbox environment is used
- no extra project-specific dev packages are added
- the workspace is still mounted normally

### Invalidation scope

When the launcher stages project package inputs for Nix evaluation, it copies only contract-related files:

- top-level `shell.nix`, `default.nix`, `flake.nix`, `flake.lock`
- files under `nix/` matching `*.nix` or `*.lock`
- extra project files listed in `nix/agent-sandbox.paths`
- extra project files listed in `AGENT_PROJECT_CONTRACT_FILES`

Changes outside that set do not invalidate the sandbox package input.

If your Nix contract depends on non-Nix files, list them explicitly in `nix/agent-sandbox.paths`:

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
2. `nix/agent-sandbox.env`
3. `.agent-sandbox.env`

The format is plain `KEY=VALUE` lines. Blank lines and `#` comments are ignored. Existing environment variables still take precedence over file values.

Example:

```sh
AGENT_CONTAINER_API=auto
AGENT_NIX_TOOL_HELPER=1
CODEX_PROFILE=work
CLAUDE_PROFILE=work
```

Only sandbox-related keys are loaded from the file, such as `AGENT_*`, tool profile/config keys, `TESTCONTAINERS_*`, and `GIT_ALLOW`.

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
- `opencode` sets `OPENCODE_PERMISSION="allow"` if it is unset

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
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/codex
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/claude
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/opencode
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/codemachine
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/omp
```

The tool-specific scripts apply the same per-tool defaults as the flake shortcuts; `./scripts/agent <tool>` remains unchanged.

## Tool Configuration Mounts

The launcher mounts host config directories into the container for supported tools.

- `codex`: host `~/.codex` to container `/config/.codex`
- `opencode`: host `~/.config/opencode` to container `/config/.opencode`
- `claude`: host `~/.claude` to container `/config/.claude`
- `omp`: host `~/.omp` to container `/cache/.omp`
- `codemachine`: mounts Codex, OpenCode, and Claude config roots together

Tool-specific profile overlays:
- `CODEX_PROFILE` overlays `<host>/.codex/profiles/<name>.json` as `auth.json`
- `OPENCODE_PROFILE` overlays `<host-config>/profiles/<name>.json` as `opencode.json`
- `CLAUDE_PROFILE` overlays `<host>/.claude/profiles/<name>.json` as `.credentials.json`

For `omp`, the launcher mounts the whole `~/.omp` tree. It does not implement a separate profile overlay layer.

## Security and Behavior

For a fuller threat model and a comparison with each supported agent's native safety model, see [docs/SANDBOX-SAFETY.md](docs/SANDBOX-SAFETY.md).

### Git inside the sandbox

The sandbox replaces `git` with a wrapper that blocks side-effecting subcommands by default.

Allowed examples:
- `status`
- `diff`
- `log`
- `show`
- `branch`
- `ls-files`
- `rev-parse`
- `blame`
- `grep`

If you need unrestricted Git, set:

```sh
GIT_ALLOW=1
```

### Agent package installation

The agent CLIs themselves are installed lazily with Bun into per-tool cache directories under `/cache/<tool>`.

This means:
- first run may install or update the tool package
- subsequent runs reuse the cached tool installation
- the image stays smaller than baking all agent npm packages directly into the root filesystem

## Performance Model

The launcher is optimized around two caches:
- Nix build outputs are stored as GC roots under `AGENT_CACHE_DIR/gcroots`
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
- `AGENT_TOOLS`: allowlist of enabled tools; defaults to `codex claude opencode codemachine omp`
- `AGENT_CACHE_DIR`: cache directory for GC roots, tool installs, and helper temp files
- `AGENT_HOST_HOME`: host home used for discovering `~/.codex`, `~/.claude`, `~/.omp`, `.gitconfig`, and similar paths

### Build, Cache, and Logs

- `AGENT_FORCE_REBUILD=1`: discard cached `rootfs` or `streamImage` artifact and rebuild it
- `AGENT_PERF_LOG=0|1`: disable or enable timing logs; default `1`
- `AGENT_NIX_EXPERIMENTAL_FEATURES`: override extra Nix experimental features; default `nix-command flakes`
- `AGENT_HELPER_TMPDIR`: temp directory for helper runs
- `AGENT_PROJECT_CONTRACT_FILES`: extra project-relative files or directories to stage for package evaluation

### Runtime behavior

- `AGENT_FORCE_TTY=1`: force `-t`
- `AGENT_MEMORY_LIMIT`: container memory limit; default `4g`
- `AGENT_CPU_LIMIT`: container CPU limit; default `2`
- `AGENT_PIDS_LIMIT`: container PID limit; default `512`
- `AGENT_WORKSPACE_HOST_PATH`: host path mounted at `/workspace`; defaults to current directory
- `AGENT_PODMAN_ROOTFS_MODE`: `auto`, `overlay`, or `mirror`; default `auto`
- `AGENT_DEV_ENV`: `host-helper` or `none`; default `host-helper`

With `AGENT_DEV_ENV=host-helper`, the launcher resolves a clean host `direnv` environment snapshot for the project root before the container starts, caches the filtered result under `AGENT_CACHE_DIR`, and passes that environment into the sandbox at startup. There is no live host `direnv` bridge in the running container; if `.envrc` changes, restart the sandbox session to refresh the injected environment.

For `.envrc` files that use `use nix` with `<nixpkgs>`, the helper first reuses the current host `NIX_PATH` if present, then falls back to the sandbox flake's locked `nixpkgs` input. If you need to force a specific `nixpkgs` tree for host-helper resolution, set `AGENT_DIRENV_NIX_PATH=/path/to/nixpkgs`.

### Nix binary cache inside container

- `AGENT_USE_LOCAL_BINCACHE=1|0`: enable or disable `file:///nixcache`; default `1`
- `AGENT_NIX_BINCACHE_DIR`: host directory mounted read-only at `/nixcache`
- `AGENT_LOCAL_BINCACHE_ALLOW_UNSIGNED=1`: allow unsigned local substitutes

### Container API access

- `AGENT_CONTAINER_API`: `none`, `auto`, `podman-session`, `podman-host`, or `docker-host`; default `none`
- `AGENT_CONTAINER_API_TTL`: inactivity timeout in seconds for `podman-session`; default `900`
- `AGENT_CONTAINER_API_RESET=1`: discard the cached `podman-session` state directory before starting it again

Recommended for Testcontainers:

- `AGENT_CONTAINER_API=auto`

In `podman-session` mode, the launcher starts a dedicated rootless Podman API service in the background, stores its state under `AGENT_CACHE_DIR`, and mounts only that session socket into the agent container. Startup does not block on socket readiness; the inner Podman API warms up in parallel with normal agent boot.

In `auto` mode, the launcher chooses `podman-session` when host Podman is available and usable, otherwise it falls back to `none`.

### Raw host socket compatibility opts

- `AGENT_ALLOW_NIX_DAEMON_SOCKET=1`: mount the host Nix daemon socket into the container
- `AGENT_ALLOW_PODMAN_SOCKET=1`: compatibility alias for `AGENT_CONTAINER_API=podman-host`
- `AGENT_ALLOW_DOCKER_SOCKET=1`: compatibility alias for `AGENT_CONTAINER_API=docker-host`

These are disabled by default because they significantly widen the sandbox boundary.

For full generic `nix-shell` and `nix shell` workflows inside the sandbox, the launcher still prepares the writable profile and gcroot directories under `/cache`, but materializing packages that are not already present in the mounted store still requires `AGENT_ALLOW_NIX_DAEMON_SOCKET=1`.

For the common “give me a tool and run it” cases, the sandbox now intercepts the narrow subset automatically:

```sh
nix shell nixpkgs#podman --command podman --version
nix-shell -p podman --run 'podman --version'
podman --version
docker version
```

Those paths use the host-backed Nix helper when possible, so the agent can keep using normal commands instead of learning sandbox-specific ones.

### Host Nix tool helper

- `AGENT_NIX_TOOL_HELPER=1|0`: enable or disable the narrow host-side Nix materialization helper; default `1`
- `AGENT_NIX_TOOL_HELPER_TTL`: inactivity timeout in seconds for the helper worker; default `900`
- `AGENT_NIX_TOOL_TIMEOUT`: request timeout in seconds for `agent-nix-tool`; default `600`

When enabled, the launcher starts a small host-side helper worker in the background and mounts a request/response bridge into the sandbox. Inside the sandbox, use:

```sh
agent-nix-tool add nixpkgs#podman
agent-nix-tool env nixpkgs#podman
agent-nix-tool run nixpkgs#podman -- podman --version
```

The helper is intentionally narrow. It only materializes constrained installables such as `nixpkgs#<attr>` and selected `github:NixOS/nixpkgs/...#<attr>` refs, using the host Nix store, without exposing the raw daemon socket to the running agent.

### Seamless command shims

The image now prefers compatibility shims over sandbox-specific instructions:

- `nix shell <installable> --command ...` is rewritten to the narrow helper path when the invocation is simple enough
- `nix-shell -p <pkg> --run ...` and `nix-shell -p <pkg> -- ...` are rewritten the same way
- `podman` and `docker` auto-materialize their CLIs on first use if they are not already available through the project contract
- Bash sessions auto-try `nixpkgs#<command>` for missing commands before falling back to the normal `command not found`

The low-level `agent-nix-tool` command is still available as an escape hatch, but normal usage should prefer the standard commands above.

### Mounts and environment passthrough

- `AGENT_EXTRA_ENV`: extra `KEY=VALUE` pairs injected into the container
- `AGENT_AUTO_MOUNT_DIRS`: comma- or newline-separated directory names to auto-mount from ancestor directories
- `AGENT_EXTRA_MOUNTS`: extra raw mount specs in `host:container[:options]` format
- `AGENT_PASS_ENV_PREFIXES`: comma- or newline-separated environment variable prefixes to forward

### Tool config overrides

- `CODEX_CONFIG_DIR`: host Codex config root; defaults to `~/.codex`
- `OPENCODE_CONFIG_DIR`: host OpenCode config root; defaults to `~/.config/opencode`
- `CLAUDE_CONFIG_DIR`: host Claude config root; defaults to `~/.claude`
- `CODEX_PROFILE`: Codex profile name to overlay from `<config>/profiles/<name>.json`
- `OPENCODE_PROFILE`: OpenCode profile name to overlay from `<config>/profiles/<name>.json`
- `CLAUDE_PROFILE`: Claude profile name to overlay from `<config>/profiles/<name>.json`
- `CODEX_PROFILE_BASE_DIR`: override Codex profile directory
- `OPENCODE_PROFILE_BASE_DIR`: override OpenCode profile directory
- `CLAUDE_PROFILE_BASE_DIR`: override Claude profile directory
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

## Ambient Host Environment

The launcher also reacts to a few standard host environment variables. These are not treated as part of the primary sandbox API:

- `CONTAINER_HOST`: if set, Podman rootfs mode is rejected; use Docker path instead
- `XDG_RUNTIME_DIR`: used to locate the rootless Podman socket when `AGENT_CONTAINER_API=podman-host`
- `XDG_CACHE_HOME`: used as the default base for `AGENT_CACHE_DIR`
- `TMPDIR`: used for helper temp files when `AGENT_HELPER_TMPDIR` is unset

## Low-Level Flake Outputs

These outputs are intended for debugging or integration work, not normal interactive use.

- `.#rootfs`: exploded root filesystem for Podman local Linux path
- `.#streamImage`: OCI image derivation for Docker path

Examples:

```sh
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

## Release

```sh
nix --extra-experimental-features 'nix-command flakes' flake show path:.
nix --extra-experimental-features 'nix-command flakes' flake update
```
