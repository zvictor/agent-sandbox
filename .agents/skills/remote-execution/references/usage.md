# Usage Reference

## Running a test

The examples below are generic. Adapt the test attribute and any flake app
names to the current repository.

Skill-local script paths are resolved relative to this skill directory, so use
the full skill-relative path when invoking them manually from the repository root.

```bash
# Generic specific Nix check attribute example
bash .agents/skills/remote-execution/scripts/run-remote-test.sh checks.x86_64-linux.some-vm-test
```

## Running an arbitrary command

Pass a single shell snippet. Quote it so it reaches the helper as one argument.

```bash
bash .agents/skills/remote-execution/scripts/run-remote-command.sh \
  'pwd && nix --version'
```

To force a bare Linux ARM64 instance for a probe or test, set `NSC_MACHINE`
with the `os/arch:` prefix before invoking the helper:

```bash
NSC_MACHINE=linux/arm64:1x2 \
  bash .agents/skills/remote-execution/scripts/run-remote-command.sh \
  'uname -m && ls -l /dev/kvm || true'
```

Do not use `nsc create --selectors arch=arm64,...` for Linux arch selection.
That selector path is documented for macOS base-image selection, not bare Linux
machine architecture.

## Running the exact GitHub Actions runner path

Use this when the failure depends on workflow orchestration, runner labels,
checkout behavior, cache layout, artifact upload, or the hosted CI environment
rather than on a generic remote Linux instance.

Dispatch a workflow on a branch:

```bash
gh workflow run 'Workflow Name' --ref my-branch
```

List the newest matching run:

```bash
gh run list --branch my-branch --workflow 'Workflow Name' --limit 1
```

Watch the run:

```bash
gh run watch <run-id>
```

Fetch structured metadata:

```bash
gh run view <run-id> --json status,conclusion,jobs
```

If a job is still running and the normal log command refuses to stream it yet,
use the per-job logs endpoint:

```bash
gh api repos/<owner>/<repo>/actions/jobs/<job-id>/logs > job.log
```

Important:
- `workflow_dispatch` only works for workflows that GitHub already knows on the default branch.
- Dispatching a workflow with `--ref <branch>` runs the workflow against that branch ref, but the workflow file itself still needs to exist on the default branch first.

## Running a local script file

Prefer this when quoting a complex shell snippet would be annoying or fragile.

```bash
bash .agents/skills/remote-execution/scripts/run-remote-script.sh ./scripts/smoke.sh
```

## Via Nix flake apps

These are example wrapper app names only. Not every repository exposes them.

```bash
nix run .#test
nix run .#test -- checks.x86_64-linux.some-vm-test
nix run .#warm-cache
```

## Warming the Nix cache (first use only)

The first run installs Nix onto the cache volume (~60s extra).
All subsequent runs detect the cached Nix binary and skip the install (<5s).

```bash
bash .agents/skills/remote-execution/scripts/ensure-nix-cache.sh
```

If the same cache volume is reused later with the same warm scope, the helper
skips the expensive prefetch work and reports that the cache was already warm.

Each helper writes:
- `execution.txt`: streamed remote stdout/stderr from the main execution phase; it may be empty on a successful silent run
- `infra.log`: instance creation, bootstrap, upload, and teardown logs
- `summary.txt`: final status, phase, exit code, saved log paths, and execution metadata

The run directory is printed immediately when the helper starts, and
`summary.txt` updates while the run is still active.

## Parallel runs

Parallel runs are safe by default because each helper allocates a fresh temp
directory for logs and artifacts.

If you want a stable location:

```bash
NSC_LOG_DIR=/tmp/remote-run-$(date +%s)-$$ \
  bash .agents/skills/remote-execution/scripts/run-remote-command.sh 'pwd'
```

Do not point multiple concurrent runs at the same `NSC_LOG_DIR`.

## Test attribute naming convention

Nix check attributes live under `checks.<system>.<name>` in the flake.
For NixOS VM tests, the system is typically `x86_64-linux`.

Examples:
- `checks.x86_64-linux.some-vm-test`
- `checks.x86_64-linux.some-smoke-test`
- `checks.x86_64-linux.some-kvm-test`

To list all available check attributes in the current flake:

```bash
nix --accept-flake-config --extra-experimental-features 'nix-command flakes' flake show 2>/dev/null | grep checks
```
