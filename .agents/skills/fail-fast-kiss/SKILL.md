---
name: fail-fast-kiss
description: Enforce replacement-first engineering for architecture, runtime, and refactor work. Use when Codex is designing or changing systems that risk accumulating legacy code, compatibility layers, graceful degradation, fallback semantics, or matrix explosion. Apply this skill to keep the codebase fail-fast, aggressively delete deprecated paths, prefer explicit capability contracts, and keep modules small, sane, and maintainable.
---

# Fail-Fast KISS

## Overview

Use this skill to keep design and implementation sharp when a system is drifting toward compatibility baggage, fallback behavior, or an overgrown support matrix.

## Core Rules

- Fail early when a required capability is missing.
- Refuse graceful degradation when it changes isolation, networking, mount, console, snapshot, security, or behavioral semantics.
- Delete deprecated, superseded, and legacy code instead of preserving it for comfort.
- Prefer one clear supported path over multiple partially supported paths.
- Keep public surfaces small and explicit.
- Keep implementation boundaries modular and narrow.
- Treat compatibility layers as debt, not as product value.

## Working Style

### Define the contract first

- State the product contract in capability terms.
- Separate user-facing profiles from backend implementation details.
- Reject unsupported combinations explicitly.

### Replace, do not accumulate

- Replace inferior paths outright when the new path is accepted as better.
- Remove dead branches, toggles, adapters, and migration-only glue in the same changeset when practical.
- Avoid carrying both old and new systems unless a current hard requirement forces it.
- If such a requirement exists, document it explicitly instead of calling it graceful degradation.

### Keep the support matrix small

- Support only the combinations that are intentional.
- Avoid optionality that multiplies testing surfaces without adding real product value.
- Collapse “advanced flexibility” back into one supported path whenever possible.

### Keep module boundaries clean

- Put shared semantics in shared modules.
- Put profile-specific behavior in profile modules.
- Put backend-specific plumbing behind a narrow interface.
- Do not leak backend command-line details into product-facing modules.

## Implementation Checklist

Before coding, answer these questions:

1. What is the single preferred path after this change?
2. Which old path becomes strictly worse or redundant?
3. What code should be deleted instead of adapted?
4. Which capability mismatches must hard-fail?
5. How can the public support matrix become smaller rather than larger?

During coding:

- Remove fallback branches that silently swap semantics.
- Remove compatibility flags that only preserve an inferior path.
- Remove deprecated code instead of marking it for later cleanup.
- Keep interfaces narrow and name ownership clearly.
- Prefer simpler data flow over clever indirection.

After coding:

- Verify unsupported combinations fail clearly.
- Verify no hidden downgrade path remains.
- Verify the docs describe one intended path, not a menu of historical leftovers.
- Verify tests cover the supported matrix only.

## Language To Prefer

- “The system supports X.”
- “If capability Y is unavailable, fail with Z.”
- “Backend A is unsupported for profile B.”
- “This change removes the superseded path.”

## Language To Avoid

- “Best effort”
- “Fallback”
- “Graceful degradation”
- “Compatibility mode” unless it is an explicit temporary constraint
- “We keep both for now” without a concrete hard requirement

## Review Heuristics

Flag the change if it:

- adds a silent fallback
- preserves two first-class paths where one should win
- introduces a compatibility toggle with no hard requirement
- expands the support matrix casually
- pushes backend-specific logic into product-profile code
- leaves deprecated code in place after replacing its behavior

Prefer the change if it:

- deletes more code than it adds
- makes unsupported cases explicit
- reduces branching and surface area
- sharpens ownership boundaries
- makes testing simpler

