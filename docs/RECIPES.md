# Recipes

These are opinionated workflows for the most common tasks. For the full knob reference, use [CONFIG.md](CONFIG.md). For the threat model, use [SANDBOX-SAFETY.md](SANDBOX-SAFETY.md).

## Daily Codex Workflow

Use this when you want the fast path with the outer sandbox and Codex yolo mode.

```sh
./scripts/agent init
./scripts/agent doctor
./scripts/codex
```

If you are not running from a checkout of this repo:

```sh
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#agent -- init
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#agent -- doctor
AGENT_PROJECT_ROOT="$PWD" nix run github:zvictor/agent-sandbox#codex
```

## Keep The Tool's Own Safety Prompts

Use `agent <tool>` instead of the shortcut wrapper.

```sh
./scripts/agent codex
./scripts/agent claude
./scripts/agent opencode
```

This keeps the outer sandbox but avoids wrapper-added bypass flags such as Codex `--yolo` or Claude `--dangerously-skip-permissions`.

## Project-Scoped Codex Login

Use this when you want sessions and config under the repo.

```sh
./scripts/agent login codex work --config project
./scripts/agent sessions codex
CODEX_CONFIG=project ./scripts/codex
```

This keeps state under `$PROJECT_ROOT/.codex`.

## One-Off Clean Run

Use a fresh config root for isolated experiments:

```sh
CODEX_CONFIG=fresh ./scripts/codex
CLAUDE_CONFIG=fresh ./scripts/claude
OPENCODE_CONFIG=fresh ./scripts/opencode
```

This starts from a clean temporary config directory for that run.

## Safer Testcontainers Setup

Prefer the high-level container API mode first:

```sh
AGENT_CONTAINER_API=auto ./scripts/agent doctor
AGENT_CONTAINER_API=auto ./scripts/codex
```

What this does:
- chooses `podman-session` when host Podman is available
- otherwise falls back to `none`
- avoids exposing the developer's main engine socket when possible

Use raw host socket modes only when `auto` cannot satisfy the workflow.

## Add A Missing Tool

Best-effort guidance:

```sh
need pnpm
```

Run once in this sandbox:

```sh
need run pnpm -- pnpm -v
need run jq -- jq --version
```

Inject the tool into the helper-managed bin dir:

```sh
need inject pnpm
need inject jq
```

Refresh the command index explicitly:

```sh
need update-index
```

## Use Standard Nix Shell Commands

The sandbox prefers normal Nix commands over sandbox-specific instructions when possible.

```sh
nix shell nixpkgs#podman --command podman --version
nix-shell -p podman --run 'podman --version'
```

When the invocation is simple enough, the launcher routes it through the narrow helper path instead of requiring raw daemon access.

## Inspect A Surprising Setup

Short summary:

```sh
./scripts/agent doctor
```

Full state dump:

```sh
./scripts/agent doctor --verbose
```

Machine-readable output:

```sh
./scripts/agent doctor --json
```

Useful when checking:
- effective runtime
- effective tool allowlist
- project root source
- config/auth selection
- helper and container API modes

## Keep State Local To The Repo

Example project defaults:

```sh
AGENT_CONTAINER_API=auto
AGENT_NEED_HELPER=1
CODEX_CONFIG=project
CLAUDE_CONFIG=project
OPENCODE_CONFIG=project
```

Bootstrap the file:

```sh
./scripts/agent init
```

This writes `.agent-sandbox.env` unless you override `AGENT_PROJECT_CONFIG_FILE`.

## Allow Full Git Temporarily

By default, the sandbox Git wrapper protects the current repo's local state and still allows `git clone`.

If you intentionally want unrestricted Git inside the sandbox:

```sh
GIT_ALLOW=1 ./scripts/codex
```

Use this narrowly. It removes one of the main guardrails.

## Raw Host Socket Escape Hatches

Only use these when the safer modes are not enough:

```sh
AGENT_CONTAINER_API=podman-host ./scripts/codex
AGENT_CONTAINER_API=docker-host ./scripts/codex
AGENT_ALLOW_NIX_DAEMON_SOCKET=1 ./scripts/codex
```

Use the Nix daemon socket path when you need full `nix build` / `nix develop` behavior inside the sandbox. Without it, the container only has a read-only `/nix` mount and generic local-store builds will fail.

These are capability bridges, not passive files. They widen the sandbox boundary materially.
