# Sandbox Safety

Updated: 2026-03-12

This document describes the safety properties of `agent-sandbox` as it exists in this repository today. It also compares those properties with the native safety models of the agent CLIs we run inside it.

The short version: this project is an outer container sandbox with a few targeted guardrails. It is materially safer than running most of these agents directly on the host, but it is not a fully sealed execution environment. In particular, the workspace is mounted read-write, outbound network is generally available, and several host capability channels can be mounted into the container.

## What Our Sandbox Actually Enforces

### 1. Container and process boundary

Interactive runs execute inside either a Podman rootfs container or a Docker-loaded OCI image, not directly on the host. The launcher drops all Linux capabilities, sets `no-new-privileges`, mounts `/tmp` as tmpfs, and applies memory/CPU/PID limits. See:

- [`container_runtime.sh`](../bin/lib/container_runtime.sh)
- [`image.nix`](../nix/image.nix)

Practically, this means agent-generated processes do not run in the host namespace with ambient host capabilities.

### 2. Filesystem scope is explicit, not ambient

The runtime does not mount the entire host home directory. Instead, it mounts:

- the selected workspace at `/workspace` as read-write
- a per-tool cache at `/cache` as read-write
- `/nix/store` as read-only when present
- selected tool config directories for the active tool
- optional extra mounts only when the caller asks for them

That is a real boundary improvement over running the CLIs directly on the host, where they inherit the caller's full filesystem access.

### 3. Host package evaluation input is narrowed

When the launcher evaluates the host project's Nix contract, it stages only the project Nix files plus explicitly allowlisted extras, instead of exposing the whole repository to Nix evaluation. See:

- [`project_contract.sh`](../bin/lib/project_contract.sh)
- [`agent`](../bin/agent)

This reduces accidental invalidation and limits what the Nix evaluation path can read from the host project.

The dev environment path is separate from this: in `AGENT_DEV_ENV=host-helper` mode, the launcher asks host `direnv` for the workspace environment at startup, caches the filtered result, and injects the resulting variables into the container. The running container does not keep a live bridge back to host `direnv`; restarting the session is the refresh path. That avoids granting the agent general access to the host Nix daemon just to get `.envrc` behavior.

### 4. Git writes are blocked by default inside the image

The base image replaces `git` with a wrapper that allows common read-only subcommands and blocks side-effecting ones unless `GIT_ALLOW=1` is set. See:

- [`image.nix`](../nix/image.nix)
- [`README.md`](../README.md)

This is useful because many agent mistakes show up first as destructive Git operations.

### 5. Tool launch defaults are centralized

The wrapper layer is opinionated about which native agent safety features stay enabled:

- `codex` shortcut wrappers add `--yolo`
- `claude` shortcut wrappers add `--dangerously-skip-permissions`
- `opencode` shortcut wrappers set `OPENCODE_PERMISSION=allow` if unset
- `codemachine` and `omp` wrappers do not add an equivalent bypass flag today

See:

- [`flake.nix`](../flake.nix)
- [`README.md`](../README.md)

This matters because for some tools our container becomes the primary safety boundary once the tool's own prompts are bypassed.

### 6. Container API access is split into safe and unsafe modes

The default launcher behavior is still no host container API access. For Testcontainers-style workflows, the preferred mode is now `AGENT_CONTAINER_API=podman-session`, which starts a dedicated rootless Podman API service with state under `AGENT_CACHE_DIR` and mounts only that session socket into the sandbox.

That is materially tighter than mounting the developer's real Podman or Docker socket directly, while still preserving a devbox-like container workflow.

## What Our Sandbox Does Not Enforce

These are the most important caveats.

### 1. The repo itself is not protected from writes

The mounted workspace is read-write. The sandbox protects the rest of the host better than a naked host run, but it does not protect the checked-out repository from edits, deletions, or generated files.

### 2. Outbound network is generally allowed

We do not currently implement a container-level network deny policy.

- Podman uses `slirp4netns` when available, but falls back to `--network=host`
- Podman on Darwin uses `--network=host`
- Docker uses its normal container network path

So this runtime is not equivalent to the built-in network restrictions offered by tools like Codex or Claude when those tools are run in their own safer native modes.

### 3. Tool config mounts are writable

For `codex`, `claude`, and `opencode`, the host config roots are mounted read-write. For `omp`, the parent `.omp` tree is mounted read-write. For `codemachine`, the container receives all three of the Codex, OpenCode, and Claude config roots.

This is convenient, but it means tokens, auth files, and tool settings are inside the blast radius of the agent.

### 4. Optional socket access is still a privilege bridge

There are two categories of container API access:

- `AGENT_CONTAINER_API=podman-session`: safer than raw host sockets, because it isolates the agent from the developer's main engine state
- raw host socket access: still available through `AGENT_CONTAINER_API=podman-host`, `AGENT_CONTAINER_API=docker-host`, or the legacy compatibility flags

The Nix daemon socket is still an explicit opt-in:

- `AGENT_ALLOW_NIX_DAEMON_SOCKET=1`

Both raw engine sockets and the Nix daemon socket are capability channels, not passive files. If an agent can talk to them, it may be able to start other containers, access broader host state, or ask the host Nix daemon to perform actions outside the container's local filesystem boundary.

`podman-session` improves this by moving container control into a dedicated reusable rootless Podman state directory, but it is not a full policy broker. An agent that can talk to that session socket can still ask that session-specific engine to create sibling containers.

This is the single biggest reason the sandbox should be described as "safer" rather than "strongly isolating".

### 5. Caller-supplied mounts and env passthrough can widen the boundary

The launcher supports:

- `AGENT_EXTRA_MOUNTS`
- `AGENT_AUTO_MOUNT_DIRS`
- `AGENT_EXTRA_ENV`
- `AGENT_PASS_ENV_PREFIXES`

Those are useful escape hatches, but each one can materially weaken the sandbox if used broadly.

### 6. First run performs networked package installation

Agent CLIs are installed lazily with Bun into `/cache/<tool>`, and the image tracks the latest package versions. That keeps the image small, but it means first-run and update paths depend on upstream package registries and network access.

## Relative Safety Rating

For the current implementation, the runtime is best described like this:

| Property | Current state |
| --- | --- |
| Host filesystem isolation outside mounted paths | Good |
| Workspace protection from agent writes | Weak |
| Credential isolation | Mixed |
| Outbound network isolation | Weak |
| Protection from accidental Git damage | Moderate |
| Protection from hostile code with access to raw host sockets | Weak |
| Protection from hostile code with `podman-session` access | Moderate |
| Resource exhaustion protection | Moderate |

## Comparison With Each Agent

### Codex

Native Codex has the richest built-in safety model of the tools here: approval policies, multiple sandbox modes, and explicit network policy support. In its safer native modes, Codex can be stricter than this repository because it can deny or escalate individual commands and can run with workspace-write or read-only semantics plus network controls.

Our `codex` shortcut intentionally adds `--yolo`, which disables Codex's own approvals and sandbox. Once that flag is in play, our container becomes the primary guardrail. That is still better than running `codex --yolo` directly on the host, but it is less nuanced than Codex's native safety stack.

Net effect:

- Better than naked `codex --yolo` on the host
- Weaker than native Codex with approvals plus a non-dangerous sandbox mode

### Claude Code

Native Claude Code has a meaningful permission model and optional Bash sandboxing. It can combine managed policies, local policies, and sandboxed command execution, which is more policy-rich than our outer container alone.

Our `claude` shortcut adds `--dangerously-skip-permissions`, so the normal Claude approval loop is bypassed. At that point, our container is the main safety layer. Compared with direct host execution, that is still an improvement, but compared with Claude's own permission system plus sandbox support, our current runtime is weaker on fine-grained approvals and weaker on network isolation.

Net effect:

- Better than naked `claude --dangerously-skip-permissions` on the host
- Weaker than native Claude with permissions and sandboxing left on

### OpenCode

OpenCode's native model is much lighter. It uses approval prompts and command policy, but it does not provide OS-level sandboxing. That means our container boundary adds a lot more real isolation than OpenCode normally has on its own.

Our `opencode` shortcut sets `OPENCODE_PERMISSION=allow` if the caller did not already choose something else. That means the container boundary, not OpenCode's prompt system, is the main protection in shortcut mode.

Net effect:

- Meaningfully stronger than running OpenCode directly on the host
- Still not a sealed sandbox because workspace, config mounts, network, and host sockets remain exposed

### CodeMachine

CodeMachine is an orchestration layer, not an OS sandbox. Its safety model is mostly about workflow structure, delegated approvals, controller behavior, and the policies of the underlying engines it launches.

That makes this repository complementary to CodeMachine rather than redundant with it. Our runtime adds process, filesystem, and resource isolation that CodeMachine itself does not provide. The catch is that our `codemachine` runtime also mounts Codex, OpenCode, and Claude config roots together, because CodeMachine may use all of them.

Net effect:

- Stronger than plain CodeMachine on the host with respect to OS-level isolation
- Still broad in credential exposure because one container may hold multiple agent config trees

### pi-coding-agent / OMP

The pi coding agent is the clearest case where external sandboxing matters. Its own model is intentionally extensible, and extensions can run arbitrary code with full system permissions. It does not rely on a built-in permission-popup safety model the way Codex, Claude, or OpenCode do.

For this tool, our container is a substantial safety improvement. It is still not complete isolation, because the workspace, `.omp` data, network, and any mounted sockets remain in scope. But compared with running OMP directly on the host, the risk reduction is real and material.

Net effect:

- Much stronger than plain host execution
- Still unsafe to treat as a hostile-code containment boundary

## The Most Important Practical Distinction

This repository is mainly an external containment layer. Most of the tools it runs were designed around one of two models:

- native approval and sandbox policy inside the agent
- little or no built-in sandboxing, with users expected to provide external isolation

For `codex`, `claude`, and `opencode` shortcut wrappers, we intentionally lean toward the second model. We relax or bypass the agent's own prompts and depend on the outer container instead. That is a legitimate design choice for already-sandboxed agent execution, but it means the quality of the outer sandbox matters more than the agent's built-in guardrails.

## Operational Guidance

If you want the safest interpretation of this repository today:

- treat it as a practical host-damage reducer, not as a hard containment boundary
- prefer `agent -- <tool>` when you want to keep the tool's own permission model intact
- prefer `AGENT_CONTAINER_API=podman-session` over raw host socket modes when container APIs are required
- avoid enabling raw Docker, Podman, or Nix daemon socket mounts unless they are required
- keep `AGENT_EXTRA_MOUNTS`, `AGENT_AUTO_MOUNT_DIRS`, and `AGENT_PASS_ENV_PREFIXES` narrow
- assume any mounted config directory may be modified or exfiltrated by the agent
- remember that the workspace is intentionally writable

## Sources

Local implementation:

- [`container_runtime.sh`](../bin/lib/container_runtime.sh)
- [`image.nix`](../nix/image.nix)
- [`project_contract.sh`](../bin/lib/project_contract.sh)
- [`rootfs.sh`](../bin/lib/rootfs.sh)
- [`agent`](../bin/agent)
- [`flake.nix`](../flake.nix)
- [`README.md`](../README.md)

Agent security models:

- Codex: <https://github.com/openai/codex>
- Claude Code: <https://github.com/anthropics/claude-code>
- OpenCode permission docs: <https://opencode.ai/docs/configuration/permission>
- OpenCode environment variables: <https://opencode.ai/docs/environment-variables>
- OpenCode repo: <https://github.com/opencode-ai/opencode>
- CodeMachine docs: <https://docs.codemachine.co/>
- CodeMachine repo: <https://github.com/moazbuilds/CodeMachine-CLI>
- pi-coding-agent repo: <https://github.com/badlogic/pi-mono>

Research method note:

- Upstream repo summaries for Codex, Claude Code, OpenCode, CodeMachine, and pi-coding-agent were gathered again during this task using Deepwiki's helper against their repositories, then reconciled with the current local implementation.
