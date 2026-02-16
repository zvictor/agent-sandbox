# Agent Sandbox

Reusable sandbox project for running `codex`, `claude`, `opencode`, and `codemachine` in a containerized environment.

## Entry points

- Flake packages: `agent`, `codex`, `claude`, `opencode`, `codemachine`
- Flake apps: `#agent`, `#codex`, `#claude`, `#opencode`, `#codemachine`
- Scripts: `./scripts/agent`, `./scripts/codex`, `./scripts/claude`, `./scripts/opencode`, `./scripts/codemachine`

## Host project contract

This sandbox is generic. The host project must provide these files:

- `<project-root>/nix/dev-packages.nix`
- `<project-root>/nix/locked-pkgs.nix`
- `<project-root>/nix/nixpkgs.lock`
- `<project-root>/nix/unstable.lock`

The preferred integration variable is:

- `AGENT_PROJECT_ROOT=/path/to/host-project`

Optional overrides:

- `AGENT_PROJECT_NIX_DIR`
- `AGENT_PROJECT_DEV_PACKAGES_FILE`
- `AGENT_PROJECT_LOCKED_PKGS_FILE`
- `AGENT_PROJECT_NIXPKGS_LOCK_FILE`
- `AGENT_PROJECT_UNSTABLE_LOCK_FILE`

If these files are missing, the sandbox fails fast.

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
            # optional convenience wrappers
            agent-sandbox.packages.${pkgs.system}.codex
            agent-sandbox.packages.${pkgs.system}.claude
            agent-sandbox.packages.${pkgs.system}.opencode
            agent-sandbox.packages.${pkgs.system}.codemachine
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
```

## Additional knobs

- `AGENT_CACHE_DIR`: wrapper cache directory
- `AGENT_TOOLS`: tools built/cached by `scripts/agent` (default: `codex claude opencode codemachine`)
- `AGENT_PASS_ENV_PREFIXES`: comma-separated env prefixes forwarded to container
- `AGENT_PASS_ENV_NAMES`: comma-separated exact env names forwarded to container
- `AGENT_AUTO_MOUNT_DIRS`: comma-separated dir names auto-mounted from ancestors
- `AGENT_EXTRA_MOUNTS`: comma-separated `host:container[:options]` mounts
- `AGENT_EXTRA_ENV`: comma-separated `KEY=VALUE` container env assignments
- `AGENT_WORKSPACE_HOST_PATH`: host path mounted at `/workspace`
- `AGENT_HASH_FILES`: comma-separated extra files included in wrapper cache hash
- `AGENT_DEBUG=1`: prints resolved project paths before build

## Legacy nix-build entry

`default.nix` is kept for compatibility:

```sh
nix-build . -A codex.wrapper
```

## Release checklist

```sh
nix --extra-experimental-features 'nix-command flakes' flake show path:.
nix --extra-experimental-features 'nix-command flakes' flake lock --update-input nixpkgs
```
