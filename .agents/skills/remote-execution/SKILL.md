---
name: remote-execution
description: >
  Run tests or heavy computations on ephemeral Namespace.so compute instances.
  Use this skill when a test requires /dev/kvm, firecracker, nested virtualization,
  or any NixOS VM-level isolation. Handles full instance lifecycle transparently:
  provision → upload workspace → run → stream logs → destroy.
  Also use it when the only trustworthy reproduction path is the exact GitHub
  Actions runner product rather than a bare Namespace instance.
  Do NOT use for tests that can run locally without KVM. Do NOT create Devboxes.
---

# Remote Namespace.so Execution

## When to use

- The user asks to run tests remotely or in a clean isolated environment.
- The local environment is not Linux or does not support nested virtualization, but the test requires it.
- Local execution would fail due to missing `/dev/kvm`.
- The local environment is already waiting on more than 4 long-running background processes.
- The local environment is too slow or unstable for the test, and a remote instance would be more reliable.
- The local environment has insufficient resources (CPU, RAM) to run the test effectively, and a remote instance would provide better performance.
- The local environment is overloaded with other tasks, and running the test remotely would free up resources and reduce interference.
- The failure appears only on the hosted CI runner product, and a bare remote instance would not be an exact enough reproduction.

## When NOT to use

- Tests that do not require KVM or virtualization.
- The user asks to open, explore, or iteratively develop in a devbox.
- The user asks to run a quick test that can easily run locally without KVM.
- The user asks to run a test that is already running locally without issues.
- The local environment is stable, responsive, and has sufficient resources to run the test effectively.
- The user asks to run a test that is not resource-intensive and does not require isolation.

## Required environment variables

Read `references/env.md` before invoking any script.
Read `references/usage.md` before choosing between bare Namespace helpers and
GitHub Actions replay.
Read the local `nsc` command reference under `references/nsc/` before making
assumptions about CLI flags, selectors, features, or instance-creation
behavior. Prefer those checked-in docs over memory when investigating
Namespace CLI behavior.
For multi-architecture bare Linux probes, do not use `--selectors` to choose
the architecture. The `nsc create` docs reserve `--selectors` for macOS base
image selection. Use the optional `os/arch:` prefix on `--machine_type`
instead, for example `linux/arm64:1x2`.
Ensure the Namespace CLI `nsc` is available in the agent environment before
running the scripts. In Nix environments, install the `namespace-cli` package.
If the CLI is not authenticated yet, run `nsc auth login` first.
When using the GitHub Actions path, ensure `gh` is installed and authenticated,
or that `GH_TOKEN` is exported with permission to dispatch workflows and read
run metadata.
Ensure `gnutar` and `gzip` are available locally before running the test helper.
Preferred preflight for this skill:
`nsc auth check-login && nsc instance upload --help`.

Skill-local script paths such as `scripts/run-remote-test.sh` are resolved
relative to this skill directory, not relative to the repository root.

Successful runs should prioritize the remote execution output itself.
Infra/bootstrap output belongs in saved logs unless debug mode is enabled or a
phase fails.

## Workflow

1. Read `references/env.md` and verify the required variables and CLI
   prerequisites are satisfied.
2. Read `references/usage.md` to confirm the correct test attribute name.
   Treat its flake attribute and app names as generic examples unless the
   current repository defines matching outputs.
3. If the Nix cache volume may be cold (first use or after a long gap),
   run `scripts/ensure-nix-cache.sh` first.
4. Choose the reproduction path that matches the failure:
   - bare Namespace helper for generic remote Linux execution
   - GitHub Actions workflow dispatch when the exact runner product, workflow
     gating, runner labels, or artifact behavior matters
5. For bare Namespace execution, choose the helper that matches the task:
   - `scripts/run-remote-command.sh '<shell-command>'` for arbitrary execution
   - `scripts/run-remote-script.sh <local-script-path>` for a local shell script file
   - `scripts/run-remote-test.sh <test-attr>` for flake check builds
6. For GitHub Actions reproduction:
   - dispatch a workflow with `gh workflow run ... --ref <branch>`
   - inspect status with `gh run list`, `gh run view`, or `gh run watch`
   - if a job is still running and `gh run view --log` is not available yet,
     fetch the per-job log stream via `gh api repos/<owner>/<repo>/actions/jobs/<job-id>/logs`
7. Report the execution output, exit code, run URL, and saved log paths to the user.
8. Never leave instances running after the script exits.
   The bare-instance scripts create an ephemeral instance, connect through
   `nsc ssh`, and destroy it automatically via EXIT trap.
9. On bare Namespace instances, expect Nix to run in single-user mode unless
   the remote image explicitly provides the `nixbld` group. The helper scripts
   handle that by passing `--option build-users-group ""` to remote Nix calls.

## Rules

- Always use ephemeral instances. Never use Devboxes for test execution.
- Start with `1x2`, the smallest available machine shape. Increase only when the current shape is clearly too small.
- Prefer standard cost-efficient shapes as you scale: `1x2` → `2x4` → `4x8` → `8x16` → `16x32` → `32x64`.
- Do not jump straight to large machines. Move up one step at a time unless the user explicitly asks otherwise.
- Never modify `NSC_DURATION` beyond 60m without explicit user instruction.
- The warm-cache step is optional and idempotent; when in doubt, run it.
- Treat a non-zero exit from the test script as a test failure, not a tool error.
- `run-remote-command.sh` expects a single shell snippet argument. Quote it.
- Prefer the GitHub Actions path over bare instances when the bug could depend
  on workflow orchestration, runner labels, checkout semantics, hosted caches,
  or CI-specific environment layout.
- `workflow_dispatch` can only target workflows that GitHub already knows on
  the default branch. A workflow file that exists only on a feature branch
  may be runnable after merge or after landing on the default branch, but not
  before.
- Default output policy:
  - full remote execution stdout/stderr is streamed live and saved to `execution.txt`
  - infra/setup logs are saved to `infra.log`
  - `execution.txt` may be empty on a successful silent run; `summary.txt` is the authoritative execution-status record
  - only surface infra detail inline when debug is enabled or a phase fails
  - if setup or execution goes quiet, emit periodic keepalive lines so agents can tell the run is still alive

## Troubleshooting

- If the terminal looks quiet, wait for the keepalive lines before assuming the run is stuck.
  Quiet setup and execution phases emit `[phase] still running ...` after the configured silence interval.
- The run directory is printed immediately at startup. Inspect `summary.txt`, `infra.log`, and `execution.txt` there while the run is still active if needed.
- `summary.txt` is live-updated during the run, not just at the end. It records the current phase, last successful phase, timing, log paths, and execution metadata such as start/finish state and whether `execution.txt` is empty.
- Parallel runs are safe by default because each helper uses a fresh temp run directory.
  Only set `NSC_LOG_DIR` when you need a stable location, and use a unique directory per concurrent run.
- If a command line is awkward to quote safely, prefer `run-remote-script.sh` over `run-remote-command.sh`.
- Use `NSC_DEBUG=1` when platform/bootstrap output matters more than a clean success path.
- Use `NSC_TRACE=1` when you want shell-level tracing from the remote script itself.
- If `gh run view --job ... --log` refuses to show logs before a run completes,
  use `gh api` against the Actions jobs endpoint for live job-specific logs.
