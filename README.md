# Agent Sandbox

Reusable sandbox project for running `codex`, `claude`, `opencode`, `codemachine`, and `omp` in a containerized environment.

## Entry points

- Flake packages: `agent`, `codex`, `claude`, `opencode`, `codemachine`, `omp`
- Flake apps: `#agent`, `#codex`, `#claude`, `#opencode`, `#codemachine`, `#omp`
- Scripts: `./scripts/agent`, `./scripts/codex`, `./scripts/claude`, `./scripts/opencode`, `./scripts/codemachine`, `./scripts/omp`

## Architecture

- `nix/image.nix`: `nix2container` `streamImage` output (Docker path) and `rootfs` output (Podman path)
- `nix/detect-packages.nix`: host project package contract detection
- `bin/agent`: runtime orchestrator (container runtime selection, mounts, profiles, sockets, env passthrough)

The base image intentionally stays lean (shell, bun, nix/direnv, network/debug tools). Heavy or project-specific tooling should come from host project `devPackages`.

Runtime modes are intentionally minimal: Podman uses a single `--rootfs ...:O` path on local Linux, and Docker uses a single `streamImage.copyToDockerDaemon` path.

## Host project contract

The sandbox auto-detects package sources in this order:

1. `<project-root>/nix/packages.nix` (recommended)
2. `<project-root>/shell.nix` (fallback)

### Option 1: `nix/packages.nix` (recommended)

```nix
{ pkgs, unstable }:
[
  pkgs.bun
  pkgs.nodejs
  pkgs.git
]
```

You may also return `{ devPackages = [ ... ]; }` for compatibility.

### Option 2: existing `shell.nix`

The shell is imported and packages are extracted from `buildInputs`, `nativeBuildInputs`, and `packages`.

```nix
{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  packages = [ pkgs.bun pkgs.nodejs pkgs.git ];
}
```

Limitations:

- `shell.nix` with complex relative imports should prefer explicit `nix/packages.nix`
- `shell.nix` that evaluates its own `<nixpkgs>` at top-level may fail under pure evaluation

## Install system-wide (NixOS)

Add this project as a flake input in your NixOS configuration and install package(s):

```nix
# host flake.nix
{
  inputs.agent-sandbox.url = "github:zvictor/agent-sandbox";

  outputs = { self, nixpkgs, agent-sandbox, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ({ pkgs, ... }: {
          environment.systemPackages = [
            agent-sandbox.packages.${pkgs.system}.agent
            agent-sandbox.packages.${pkgs.system}.codex
            agent-sandbox.packages.${pkgs.system}.claude
            agent-sandbox.packages.${pkgs.system}.opencode
            agent-sandbox.packages.${pkgs.system}.codemachine
            agent-sandbox.packages.${pkgs.system}.omp
          ];
        })
      ];
    };
  };
}
```

Then run it from a host project:

```sh
AGENT_PROJECT_ROOT="$(git rev-parse --show-toplevel)" agent codex
```

## Install locally per project (recommended)

### Option A: via project flake devShell

```nix
# host project flake.nix
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

### Option B: host wrapper script

```sh
#!/usr/bin/env bash
set -euo pipefail

project_root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
export AGENT_PROJECT_ROOT="$project_root"
exec agent "$@"
```

## No installation (one-off)

```sh
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#agent -- codex
```

Local checkout variant:

```sh
AGENT_PROJECT_ROOT="$PWD" nix run path:/path/to/agent-sandbox#agent -- codex
```

## Direct script usage from this repo

```sh
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/agent codex
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/codex
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/claude
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/opencode
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/codemachine
AGENT_PROJECT_ROOT=/path/to/host-project ./scripts/omp
```

## Additional knobs

- `AGENT_PROJECT_ROOT`: host project root (defaults to current git top-level / cwd)
- `AGENT_PROJECT_NIX_DIR`: override project nix dir (defaults to `$AGENT_PROJECT_ROOT/nix`)
- `AGENT_SANDBOX_FLAKE_REF`: override sandbox flake reference (example: `path:/abs/path/to/agent-sandbox`)
- `AGENT_RUNTIME`: `podman` or `docker` (default auto-detect)
- `AGENT_TOOLS`: allowed tool list (default: `codex claude opencode codemachine omp`)
- `AGENT_CACHE_DIR`: runtime cache directory
- `AGENT_HOST_HOME`: host home override for profile/config discovery (`~/.codex`, `~/.claude`, `~/.omp`, `.gitconfig`, etc.)
- `AGENT_FORCE_REBUILD=1`: ignore cached stream image and reload
- `AGENT_FORCE_TTY=1`: force `-t` even in non-tty pipelines
- `AGENT_MEMORY_LIMIT`, `AGENT_CPU_LIMIT`, `AGENT_PIDS_LIMIT`: container limits
- `AGENT_USE_LOCAL_BINCACHE=1|0`: enable/disable `/nixcache` substituter
- `AGENT_NIX_BINCACHE_DIR`: host local Nix cache bind mount (read-only)
- `AGENT_LOCAL_BINCACHE_ALLOW_UNSIGNED=1`: allow unsigned local substitutes
- `AGENT_PASS_ENV_PREFIXES`: newline/comma-separated env prefixes to forward
- `AGENT_AUTO_MOUNT_DIRS`: comma-separated dir names auto-mounted from ancestors
- `AGENT_EXTRA_MOUNTS`: comma-separated `host:container[:options]` mounts
- `AGENT_EXTRA_ENV`: comma-separated `KEY=VALUE` env pairs passed to container
- `AGENT_WORKSPACE_HOST_PATH`: host path mounted at `/workspace` (defaults to `$PWD`)
- `AGENT_DEBUG=1`: print resolved paths and runtime details
- `AGENT_PERF_LOG=0|1`: enable/disable build/load timing logs (`1` by default)

Wrapper outputs are registered as GC roots under `AGENT_CACHE_DIR`, so periodic
`nix-collect-garbage` runs do not invalidate the cached stream image derivation.

## Release checklist

```sh
nix --extra-experimental-features 'nix-command flakes' flake show path:.
nix --extra-experimental-features 'nix-command flakes' flake update
```
