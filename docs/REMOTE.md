# Remote sandboxes

Remote mode creates a durable sandbox endpoint for one worktree. The host
terminal and a phone SSH client both attach to the same tmux-backed processes
inside that sandbox.

This is not official Codex Mobile. It is a Linux-native SSH workflow over a
Tailscale sidecar.

## Quick start

From the worktree you want to expose:

```sh
AGENT_REMOTE_TS_AUTHKEY_FILE=~/.config/agent-sandbox/tailscale-authkey \
AGENT_REMOTE_AUTHORIZED_KEYS_FILE=~/.ssh/authorized_keys \
./scripts/agent remote up
```

Start or attach Codex from the host:

```sh
./scripts/agent remote codex
```

From the phone, connect through Tailscale:

```sh
ssh codex@<remote-hostname>
```

The SSH login attaches to the existing `codex` tmux session when one is
running. If no Codex tmux session exists, it opens a shell tmux session.

## Mental model

```text
host terminal
  -> podman exec
  -> remote runtime container
  -> tmux session

phone
  -> Tailscale tailnet
  -> Tailscale sidecar
  -> OpenSSH on 127.0.0.1:2222 in the runtime container
  -> same tmux session
```

`agent remote up` starts the durable endpoint. It does not attach to an
already-running foreground `./scripts/codex` process. Sessions that may need
phone continuation should be started with `agent remote codex`.

## Commands

```sh
./scripts/agent remote up
./scripts/agent remote status
./scripts/agent remote codex
./scripts/agent remote attach
./scripts/agent remote ssh
./scripts/agent remote sessions
./scripts/agent remote down
```

Use `--name NAME` to override the worktree-derived endpoint name:

```sh
./scripts/agent remote up --name api-refactor
./scripts/agent remote codex --name api-refactor
```

Use `--start-codex` or `--resume` when starting the endpoint:

```sh
./scripts/agent remote up --start-codex
./scripts/agent remote up --resume last
./scripts/agent remote up --resume <SESSION_ID>
```

## Acceptance test

Run this on the NixOS host with a real Tailscale auth key and the SSH public
key used by the phone:

```sh
AGENT_REMOTE_TS_AUTHKEY_FILE=~/.config/agent-sandbox/tailscale-authkey \
AGENT_REMOTE_AUTHORIZED_KEYS_FILE=~/.ssh/authorized_keys \
./scripts/agent remote up --start-codex
```

The command should print a stable `ssh codex@...` endpoint. In another host
terminal:

```sh
./scripts/agent remote sessions
```

The `Live tmux sessions` section should include `codex`. From the phone, while
connected to the same tailnet:

```sh
ssh codex@<remote-hostname>
```

The phone should attach to the same live Codex tmux session. Disconnecting the
phone or host terminal must not stop the sandbox; `./scripts/agent remote
status` should still show the runtime and Tailscale containers as running until
`./scripts/agent remote down` is executed.

## Scope

By default, the endpoint name is derived from the current worktree path. Running
`agent remote up` from different worktrees creates different pods, containers,
Tailscale hostnames, SSH endpoints, and tmux state.

Remote mode defaults Codex to project config so each worktree has separate
session visibility:

```sh
./scripts/agent remote up
./scripts/agent remote codex
```

This behaves like:

```sh
CODEX_CONFIG=project ./scripts/agent remote up
CODEX_CONFIG=project ./scripts/agent remote codex
```

`CODEX_CONFIG=project` keeps visible Codex transcripts under the worktree's
`.codex/sessions`, so they remain attached to the worktree when it is moved or
copied. Set `CODEX_CONFIG=host` explicitly only when the remote sandbox should
share host `~/.codex`; that exposes broader history and config state to the
remotely reachable sandbox.

## Required inputs

Remote mode needs a Tailscale login credential for the sidecar on first start.
Use a tagged, scoped auth key:

```sh
AGENT_REMOTE_TS_AUTHKEY_FILE=~/.config/agent-sandbox/tailscale-authkey
```

You can also use:

```sh
AGENT_REMOTE_TS_AUTHKEY=<auth-key>
AGENT_REMOTE_TS_CLIENT_ID=<oauth-client-id>
AGENT_REMOTE_TS_CLIENT_SECRET=<oauth-client-secret>
```

The phone also needs an SSH public key accepted by the runtime container:

```sh
AGENT_REMOTE_AUTHORIZED_KEYS_FILE=~/.ssh/authorized_keys
```

or:

```sh
AGENT_REMOTE_AUTHORIZED_KEY='ssh-ed25519 AAAA... phone'
```

## Tailscale auth key setup

Remote sandboxes should join the tailnet as tagged service devices. Use a tag
such as `tag:codex-agent` and grant your phone or operator group access only to
TCP port 22 on that tag. This project uses normal OpenSSH inside the sandbox;
do not enable Tailscale SSH for this path.

First, add the tag and the narrow network grant in the Tailscale admin console
policy editor:

```json
{
  "groups": {
    "group:codex-operators": ["you@example.com"]
  },
  "tagOwners": {
    "tag:codex-agent": ["autogroup:admin"]
  },
  "grants": [
    {
      "src": ["group:codex-operators"],
      "dst": ["tag:codex-agent"],
      "ip": ["tcp:22"]
    }
  ]
}
```

If your tailnet still has a broad grant such as `src: ["*"]`,
`dst: ["*"]`, `ip: ["*"]`, that broader rule also applies. Remove or narrow
those broad rules if the Codex sandbox should only be reachable by the operator
group.

Then create the auth key from the Tailscale admin console:

1. Open the **Keys** page.
2. Select **Generate auth key**.
3. Use a description such as `agent-sandbox remote codex`.
4. Enable **Tags** and select `tag:codex-agent`.
5. Use **Reusable** only when one key should bootstrap several worktree
   sandboxes. For the narrowest setup, create a one-off key per sandbox.
6. Set the key expiry as short as practical. A reusable key should usually use
   the minimum practical number of days, not the maximum expiry.
7. Enable **Pre-approved** only if device approval is enabled and these sandbox
   nodes should join without an additional admin approval.
8. Leave **Ephemeral** off for durable remote sandboxes. The sidecar persists
   Tailscale state so the same node identity survives restarts. Use ephemeral
   keys only for intentionally disposable sandboxes that you will stop with
   `agent remote down --delete-state`.
9. Do not enable Tailscale SSH for this workflow. Phone access goes through
   Tailscale network ACLs to OpenSSH inside the runtime container.

Store the key in a private file instead of exporting it in shell history:

```sh
mkdir -p ~/.config/agent-sandbox
umask 077
$EDITOR ~/.config/agent-sandbox/tailscale-authkey
```

The file should contain only the auth key:

```text
tskey-auth-...
```

Use that file when starting the remote endpoint:

```sh
AGENT_REMOTE_TS_AUTHKEY_FILE=~/.config/agent-sandbox/tailscale-authkey \
AGENT_REMOTE_AUTHORIZED_KEYS_FILE=~/.ssh/authorized_keys \
./scripts/agent remote up
```

After all intended durable sandboxes have joined and have persistent state, you
can revoke the auth key from the Tailscale **Keys** page. Revoking the auth key
prevents future joins with that key; it does not remove devices that already
joined. Remove stale sandbox nodes from the **Machines** page when they are no
longer needed.

For long-lived automation, prefer Tailscale OAuth credentials over a reusable
static auth key. Remote mode also accepts `AGENT_REMOTE_TS_CLIENT_ID` and
`AGENT_REMOTE_TS_CLIENT_SECRET`; keep the same `tag:codex-agent` policy and
grant shape.

References: Tailscale documents auth key types, expiry, device settings, and
best practices in the [auth keys guide](https://tailscale.com/docs/features/access-control/auth-keys).
The container sidecar variables used here are documented in
[Docker configuration parameters](https://tailscale.com/docs/features/containers/docker/docker-params).
The `tagOwners` and `grants` policy syntax is documented in the
[tailnet policy file reference](https://tailscale.com/docs/reference/syntax/policy-file).

## Safety contract

Remote mode supports one main path:

- Linux host
- local rootless Podman
- Podman `--rootfs` runtime
- no host-published ports
- Tailscale userspace sidecar
- OpenSSH inside the sandbox on `127.0.0.1:2222`
- Tailscale Serve forwarding tailnet TCP/22 to that local SSH port

Remote mode refuses host-network fallback when `slirp4netns` is unavailable.

Remote mode does not silently inherit these host bridges:

- `AGENT_CONTAINER_API=auto`, `podman-session`, `podman-host`, or `docker-host`
- raw Podman or Docker socket compatibility flags
- raw Nix daemon socket access
- host Nix helper access
- host SSH agent forwarding

When `AGENT_REMOTE_ALLOW_CONTAINER_API` is not set, remote mode forces
`AGENT_CONTAINER_API=none`. When `AGENT_REMOTE_ALLOW_NEED_HELPER` is not set,
remote mode forces `AGENT_NEED_HELPER=0`. Explicit raw sockets, extra mounts,
extra devices, and broad environment overrides still fail until opted in.

Remote runtime artifacts and any explicitly enabled `need` outputs are retained
by a host-owned lease under the remote state directory. The container receives
only `/run/agent-runtime-receipts` read-only and the narrow helper bridge when
enabled. `agent remote down` removes the lease after stopping the containers;
ordinary launcher exit does not release it.

Use explicit opt-ins only when the wider boundary is intentional:

```sh
AGENT_REMOTE_ALLOW_CONTAINER_API=1
AGENT_REMOTE_ALLOW_NEED_HELPER=1
AGENT_REMOTE_ALLOW_NIX_DAEMON=1
AGENT_REMOTE_ALLOW_EXTRA_MOUNTS=1
AGENT_REMOTE_ALLOW_EXTRA_DEVICES=1
AGENT_REMOTE_ALLOW_AUTO_MOUNTS=1
AGENT_REMOTE_ALLOW_EXTRA_ENV=1
AGENT_REMOTE_ALLOW_HOST_ENV=1
AGENT_REMOTE_FORWARD_SSH_AGENT=1
```

The `firecracker-host` profile is available only with explicit friction because
it uses privileged host-control semantics. In an interactive shell, remote mode
requires typing `firecracker-host` before it starts. For non-interactive use,
set:

```sh
AGENT_REMOTE_ALLOW_PRIVILEGED_HOST_CONTROL=I_UNDERSTAND
```

That profile uses the existing `firecracker-host` preflight checks and runs the
remote runtime and Tailscale sidecar through `sudo -n podman` with host
networking and `CAP_NET_ADMIN` for tap setup. It does not require host
Tailscale or host sshd.
