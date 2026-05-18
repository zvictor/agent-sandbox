---
name: need-command-injection
description: Recover missing shell commands in sandboxed environments by using `need lookup`, `need run`, and `need inject` to materialize Nix packages on demand. Use when a command fails with `command not found`, when stderr explicitly suggests `need`, or when Codex needs a temporary tool such as `python3`, `rustc`, `cargo`, `tar`, or `gzip` without editing project files.
---

# Need Command Injection

## Overview

Use `need` to recover from missing executables in the current sandbox without patching repository files. Prefer it after an actual command failure or when the environment has already shown that the tool is absent.

## Workflow

1. Run the intended command normally first when that is cheap and safe.
2. If stderr says the program is not available and prints `need` guidance, use the suggested `need` form instead of guessing package names.
3. Choose `need run` for one-shot execution and `need inject` when the same executable will be reused.
4. Rerun the original command or a quick `--version` check to verify the tool is now available.
5. Continue the actual task only after the tool works.

## Command Selection

### `need lookup <command>`

Use to discover the best Nix package match before trying an installable by hand. Expect output that includes:

- the best match in nixpkgs
- alternative matches
- an exact `need run ...` form
- an exact `need inject ...` form

Prefer the printed command over manual package-name guessing.

### `need run <command-or-installable> -- <command> [args...]`

Use for one-off work such as:

- checking a version
- running a validator once
- executing a bootstrap script one time
- avoiding persistent shell changes when the tool is not needed again

Examples:

```sh
need run rustc -- rustc --version
need run python3 -- python3 /path/to/script.py
need run nixpkgs#jq -- jq --version
```

Treat `need run` as non-persistent. If the tool is needed again later, either repeat `need run` or switch to `need inject`.

### `need inject <command-or-installable>`

Use when multiple follow-up commands need the same executable in this sandbox session.

Examples:

```sh
need inject rustc
rustc --version
rustc --print sysroot
```

After injection, rerun the real command normally. Do not keep prefixing later calls with `need run` unless you intentionally want one-shot execution.

### Explicit Installables

Bare names such as `rustc`, `cargo`, and `python3` resolve through `need`'s lookup behavior and default to `nixos-unstable`. Use explicit installables such as `nixpkgs#jq` when the command name is ambiguous or when a specific package reference is required.

## Practical Rules

- Prefer the exact remediation command printed by the failing command's stderr.
- Prefer `need run` for a single command and `need inject` for repeated usage.
- Prefer `need lookup` when the package choice is unclear before injecting anything.
- Do not edit `flake.nix` or other project files just to fix a transient sandbox tool gap unless the user asks for a project-level fix.
- If `need` materialization fails, stop guessing and surface the actual error.

## Observed Patterns

These patterns were verified in this environment and are safe defaults to follow:

```sh
rustc --version
# If missing, stderr suggests:
#   need run rustc -- rustc ...
#   need inject rustc
```

```sh
need lookup cargo
# Shows the best match plus exact run/inject commands.
```

```sh
need inject rustc
rustc --version
# Injection makes later rustc commands work normally in this sandbox session.
```
