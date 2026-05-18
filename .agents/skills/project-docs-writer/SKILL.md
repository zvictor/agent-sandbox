---
name: project-docs-writer
description: Write user-friendly, extensive, and well-structured documentation for any software project. Covers READMEs, guides, API references, architecture docs, and onboarding materials. Designed for human readers first, completeness second.
tags:
  - documentation
  - writing
  - developer-experience
  - onboarding
version: 1.0.0
author: Documentation Agent
---

# Project Documentation Writer Skill

## Overview

A skill for producing documentation that is both genuinely useful to a newcomer and complete enough to serve as a long-term reference. The guiding principle is **progressive disclosure**: a reader should be able to stop reading at any depth and still be productive at that level.

This skill does not template-fill. It reads the project, understands what it does, and writes documentation that reflects reality - not what the project aspires to be.

---

## Core Philosophy

### Human readers first

Documentation exists for people, not for coverage metrics. Every section must answer a real question a real reader would have. If you cannot articulate who reads a section and what they need from it, do not write it.

### Progressive disclosure, not data dumps

Structure every document so that the most urgent information comes first. Readers who only need the quick-start should not have to scroll past architecture diagrams. Readers who need to understand the internals should be able to find that layer without it cluttering the surface.

### Show, then explain

Lead with a working example before explaining mechanics. A reader who sees what the thing does will understand the explanation far better than one who reads the theory cold.

### Documentation is a product

It has users, it can have bugs, and it degrades over time. Treat it with the same care as code.

---

## When to Use This Skill

### Perfect for:
- ✅ Writing or rewriting a project README from scratch
- ✅ Creating onboarding guides for new contributors or users
- ✅ Documenting APIs, CLIs, configuration, and environment variables
- ✅ Writing architecture system overviews
- ✅ Producing changelog and migration guides
- ✅ Auditing existing documentation for gaps, staleness, or incoherence

### Not suitable for:
- ❌ Auto-generating API references directly from code comments (use JSDoc/Typedoc/Sphinx for that)
- ❌ Writing inline code comments (that is a separate concern from user-facing docs)
- ❌ Legal, compliance, or contractual documentation

---

## Workflow

### Step 1 - Understand the project before writing anything

Before writing a single line, answer these questions by reading the codebase, existing docs, and any READMEs:

1. **What does this project do?** One sentence. If you cannot write it, the docs cannot either.
2. **Who uses it?** End users? Other developers? Operators deploying it? Each audience needs different language and depth.
3. **What is the entry point?** What does a person do first? Install, clone, run a command?
4. **What can go wrong?** Common errors, environment assumptions, known limitations.
5. **What is NOT documented yet?** Gaps are the highest-value places to write.

Do not skip this step. Documentation written without understanding the project produces accurate-sounding lies.

### Step 2 - Write in layers, not in order

Write each document starting from the surface and moving toward depth. Validate each layer before going deeper:

```
Layer 1 (surface)   → What is this? How do I get started? One working example.
Layer 2 (usage)     → Common use cases. Core concepts. Most-used options.
Layer 3 (reference) → Full API / config / CLI reference. Every option documented.
Layer 4 (internals) → Architecture, data flows, design decisions, contribution paths.
```

A reader should be able to stop at any layer and still be able to use the project.

### Step 3 - Validate against real reader scenarios

Before finalising, walk through the docs as each of the following personas:

- **The newcomer**: Can they install and run the project using only the README? No prior knowledge assumed.
- **The occasional user**: Can they find the answer to a specific question in under 30 seconds?
- **The contributor**: Do they understand how the project is structured and how to make a change?
- **The operator**: Do they know every environment variable, config option, and failure mode?

If any persona gets stuck, fix the gap before publishing.

---

## Document Specifications

### README

The README is the front door. It must be immediately useful and never assume prior knowledge.

**Required sections in order:**

```markdown
# Project Name

One sentence: what this does and for whom.

## Quick Start

The shortest possible path from zero to working. No explanation - just commands.

    npm install my-project
    my-project init
    my-project run --example

Expected output (copy the real output here, not a description of it).

## What It Does

2-4 sentences of honest, concrete description. No marketing language.
Include a real example with input and output.

## Requirements

Minimum versions. External dependencies. Platform assumptions.

## Installation

Full installation steps, including environment setup if needed.

## Usage

The 3-5 most common use cases with working examples.

## Configuration

Link to full config reference, or include it here if it is short.

## Contributing

Link to CONTRIBUTING.md, or a one-paragraph summary.

## License
```

**README rules:**
- The Quick Start must work without reading any other section.
- Every code block must be copy-pasteable and produce real output.
- If setup requires environment variables, show exactly what they look like.
- Never write "please" or "simply" or "just" - these words make failures feel like the reader's fault.
- Do not put architecture diagrams, ADRs, or internal details in the README. Those have their own homes.

---

### Quick-Start Guide

Written for a person who has never seen the project and wants to produce something real in under 10 minutes.

**Structure:**
1. Prerequisites (exact versions, nothing vague like "recent Node")
2. Installation (one block, copy-pasteable)
3. The minimal working example (input → command → expected output)
4. The next most useful thing to try
5. Where to go from here (links to usage guide, config reference)

**Rules:**
- Every step must be a concrete action. No "make sure you have" without a verification command.
- Show expected output after every command that produces it.
- If a step can fail, say what the failure looks like and how to fix it.

---

### Configuration Reference

A complete listing of every option the project accepts - flags, environment variables, config file keys, or any combination.

**Format for each option:**

```markdown
### OPTION_NAME

| Property    | Value                        |
|-------------|------------------------------|
| Type        | string                       |
| Default     | `"production"`               |
| Required    | No                           |
| Environment | `MY_PROJECT_OPTION_NAME`     |
| Since       | v1.2.0                       |

Description: what this option controls and why someone would change it.

**Example:**

    MY_PROJECT_OPTION_NAME=staging my-project run

**Notes:** edge cases, interactions with other options, deprecation notices.
```

**Rules:**
- Document every option, even ones you think are obvious.
- Group related options under a heading.
- If an option has a default, state it explicitly - "none" is also a valid default.
- If an option was added in a specific version, note it. This helps users on older versions.
- If an option interacts with another, link between them.

---

### API Reference

For library APIs, REST APIs, CLIs, or any public contract.

**For each method / endpoint / command, document:**

1. **Signature / path / command** - the exact syntax
2. **Purpose** - one sentence
3. **Parameters / arguments / flags** - name, type, required/optional, default, description
4. **Return value / response** - shape, type, status codes
5. **Example** - a real invocation with real input and real output
6. **Errors** - what can go wrong, what the error looks like, how to fix it

**Rules:**
- Group by resource, feature, or workflow - not alphabetically. Alphabetical is for indices, not for learning.
- Provide at least one complete, runnable example per entry - not a partial snippet.
- Document error responses with the same rigour as success responses.
- If the API has a deprecation, say so at the top of that entry, with what to use instead and since when.

---

### Architecture Overview

For projects where components, data flows, or design decisions are non-obvious.

**Structure:**
1. **System map** - a diagram or ASCII art showing the major components and how they connect
2. **Data flow** - how data moves through the system for the primary use case
3. **Key abstractions** - the 3-5 central concepts or interfaces a contributor must understand
4. **What lives where** - a brief directory guide for the important parts of the codebase
5. **Design decisions** - why the non-obvious choices were made (or link to ADRs)

**Rules:**
- The system map must be accurate to the current codebase, not to aspirations.
- Label every component in the diagram with the actual module / service / file name.
- Do not describe implementation details here. Architecture is about structure and intent, not code.

**Directory guide template:**
```
src/
  core/       - domain logic; no I/O
  adapters/   - I/O: database, HTTP, filesystem
  api/        - public interface; thin layer over core
  config/     - configuration loading and validation
tests/
  unit/       - core logic tests, no I/O
  integration/- tests that touch real I/O
```

---

### Troubleshooting Guide

A catalogue of real failures with real fixes.

**Format for each entry:**

```markdown
### Error: <exact error message or symptom>

**When this happens:** the condition that triggers this error.

**Why it happens:** the root cause in plain language.

**Fix:**

    command or config change that resolves it

**If that does not work:** secondary causes, escalation path, or link to issue tracker.
```

**Rules:**
- Use the exact error message as the heading. Readers will Ctrl+F for it.
- Do not document errors that have never been seen in production. Only document real failures.
- If the fix has prerequisites, list them before the fix.

---

### Contributing Guide

For projects that accept external contributions.

**Required sections:**
1. **Development setup** - exact steps to get a working local environment
2. **How to run tests** - command, what to expect, how to add a test
3. **Code style and conventions** - linter, formatter, commit message format
4. **How to submit a change** - branch naming, PR process, review expectations
5. **What we accept** - scope of contributions; what to discuss before writing code
6. **What we do not accept** - saves everyone time

---

## Writing Rules

### Language

- **Active voice.** "Run the command" not "The command should be run."
- **Present tense.** "Returns a string" not "Will return a string."
- **Concrete nouns.** "The config file at `~/.myproject/config.yaml`" not "your configuration."
- **No filler words.** Delete: simply, just, easily, obviously, basically, note that, please, very.
- **No future promises.** Document what the project does now, not what it will do.

### Code blocks

- Every code block must be copy-pasteable and produce real output.
- Show the command prompt (`$`) for shell commands so readers know it is a command, not output.
- Show expected output below the command. Mark it clearly if it is abbreviated.
- Use syntax highlighting (` ```bash `, ` ```json `, ` ```python ` etc.).
- If a block requires substitution, use `<ANGLE_BRACKETS>` for required values and `[SQUARE_BRACKETS]` for optional ones.

### Links and cross-references

- Link the first occurrence of a concept in each document to where it is defined.
- Do not link the same term multiple times in the same section.
- Use relative paths for links within the docs so they survive domain changes.
- Every link must be verified to exist before publication.

### Headings

- Headings are navigation aids, not decoration. Every heading should answer "what do I find here?"
- Use sentence case, not Title Case for every word.
- Do not skip levels (never jump from `##` to `####`).
- A section with only one subsection does not need a heading hierarchy - collapse it.

---

## Common Documentation Mistakes

| Mistake | Problem | Fix |
|---|---|---|
| Documenting aspirations | Creates trust failure when reality differs | Only document current behaviour |
| Burying the quick start | Readers leave before finding it | Quick start is always the first section |
| Vague prerequisites | "You need Node installed" | "Node.js >= 18.0.0 (`node --version` to check)" |
| Missing expected output | Reader cannot tell if the command worked | Always show what success looks like |
| Explaining what instead of why | Reader follows instructions but cannot adapt | Always pair what with why for non-obvious choices |
| Assuming vocabulary | "Configure the adapter" with no prior definition | Define every domain term on first use |
| Single monolith document | Readers cannot navigate or link to sections | Split by audience and depth layer |
| Stale examples | Code examples that no longer work | Date-stamp any version-sensitive example |

---

## File Structure

```
docs/
├── README.md                 - Project front door
├── quick-start.md            - Zero to working in under 10 minutes
├── configuration.md          - Complete config reference
├── api/
│   ├── overview.md           - API concepts and authentication
│   └── reference.md          - Full endpoint / method reference
├── architecture.md           - System structure and design rationale
├── contributing.md           - How to contribute
├── troubleshooting.md        - Common errors and fixes
├── changelog.md              - Version history
```

This structure is a starting point. Use only the documents the project actually needs.

---

## Maintenance Rules

Documentation rots. Apply these rules to slow the decay:

1. **Every PR that changes behaviour must include a documentation update.** No code merge without a corresponding docs change if the public interface or user behaviour changes.
2. **Date-stamp version-sensitive content.** If an example only applies to v2+, say so.
3. **Audit quarterly.** Read the quick-start with fresh eyes. If it breaks, fix it.
4. **Delete outdated content outright.** A section that says "as of v1, this worked differently" is noise. Remove it or archive it.
5. **Track documentation bugs like code bugs.** Open issues for doc gaps with the same rigour as code defects.

---

## Version History

- **v1.0.0** - Initial release
  - Progressive disclosure workflow
  - Document specifications for all common types
  - Writing rules, common mistakes, maintenance guidelines

---

**Remember:** documentation is finished when a stranger can use the project without asking you a question. Until that bar is met, it is not done.
