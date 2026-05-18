---
name: deepwiki
description: Use DeepWiki to build up-to-date, accurate understanding of any external tool, library, or framework before using it. Consider DeepWiki your first line of research before writing code that uses an external dependency or tool, and use it aggressively and early in the development process.
tags:
  - research
  - documentation
  - external-tools
  - cli
version: 3.1.0
---

# DeepWiki Skill

## Overview

DeepWiki provides grounded answers over public GitHub repositories. Use it before writing code against an external tool, library, framework, API, or documentation set that lives in a GitHub repository.

It reflects the actual current state of the codebase rather than your outdated training data.

Use it **aggressively and early**. Do not rely on memorised knowledge for external tools; it may be stale, wrong, or version-mismatched.

DeepWiki should be preferred over general web search whenever the relevant source material exists in a GitHub repository.

That includes:

- application or library source repositories
- official docs-source repositories
- dedicated documentation repositories that are separate from the main product codebase

In this repository, the primary interface is the Bun TypeScript client at `scripts/deepwiki.ts`. It submits a query once, polls the canonical `/ada/query/:id` endpoint until completion, and renders the final answer from the completed query JSON. Progress is derived from intermediate response events and goes to `stderr`; final answer text goes to `stdout`.

Always try the TypeScript client first. Use MCP only when the CLI path is unavailable or clearly broken.

All command examples below assume your working directory is `.agents/skills/deepwiki`.

## When To Use DeepWiki

- Understand how an upstream library or framework really works before writing code against it
- Verify API shapes, configuration formats, method signatures, or command semantics
- Inspect architecture, control flow, or code paths in an external repository
- Read and summarize official documentation when that documentation lives in a GitHub repo
- Research hosted-product setup steps when the vendor publishes the docs in Git
- Resolve ambiguity between multiple implementation approaches
- Onboard into a new technology stack quickly and accurately without guessing work.

Default rule: if you are unsure how an external tool behaves, query DeepWiki before guessing.

Default rule for research:

- first find the correct GitHub repository
- then prefer DeepWiki over web search
- use web search only to discover the correct repo when the repository is not already known
- when the repository is known but not yet indexed, run `bun ./scripts/deepwiki.ts status owner/repo --warm`

## Access Modes

```text
1. TS client (primary) -> bun ./scripts/deepwiki.ts
2. MCP (fallback)      -> mcp.deepwiki.com
```

## Mode 1 — TS Client

### Primary commands

```bash
bun ./scripts/deepwiki.ts query "question" owner/repo [owner/repo2 ...] \
  [--mode deep|fast|codemap] [--context "text"] [--id query-id] \
  [--mermaid] [--sources-only] [--json]

bun ./scripts/deepwiki.ts start "question" owner/repo [owner/repo2 ...] \
  [--mode deep|fast|codemap] [--context "text"] [--id query-id] [--no-summary]

bun ./scripts/deepwiki.ts wait query-id [--mode codemap] [--mermaid] \
  [--sources-only] [--json]

bun ./scripts/deepwiki.ts status owner/repo [--warm]
bun ./scripts/deepwiki.ts warm owner/repo
bun ./scripts/deepwiki.ts get query-id
bun ./scripts/deepwiki.ts list search-term
```

### Query behavior

- `query` submits and waits until DeepWiki finishes.
- `start` submits and returns a `query_id` immediately. Use it when `deep` mode may outlive your shell session or host timeout.
- `wait` reattaches to an existing `query_id` and renders the same final output as `query`.
- `get` returns the raw query JSON for inspection.

The client prints:

1. answer prose
2. grounded source file paths
3. `Query-ID` for resuming or follow-up queries
4. `Message-ID` when DeepWiki returns one

### Query IDs, not thread IDs

`--id` reuses a DeepWiki `query_id`. It is not the rendered `Message-ID`.

If you want to continue an existing DeepWiki conversation, reuse the previous `Query-ID`:

```bash
bun ./scripts/deepwiki.ts query "What changed in the retry path?" owner/repo --id <query-id>
```

If a long-running `deep` query gets interrupted locally, resume it with:

```bash
bun ./scripts/deepwiki.ts wait <query-id>
```

### Modes

| Mode | When to use |
|---|---|
| `deep` | Use for non-trivial implementation questions when `fast` does not provide enough depth |
| `fast` | Default for the TypeScript client in `scripts/deepwiki.ts`; use first for straightforward repo-grounded questions and normal implementation research |
| `codemap` | Architecture, control flow, trace questions, and Mermaid diagram generation |

### Progress

`DEEPWIKI_PROGRESS_MODE` controls progress on `stderr`:

| Value | Behavior |
|---|---|
| `auto` | show progress only when `stderr` is a TTY |
| `plain` | always show plain progress lines |
| `quiet` | suppress progress lines |

### Examples:

```bash
# Standard implementation research
bun ./scripts/deepwiki.ts query "How does the plugin lifecycle work?" vitejs/vite

# Force visible progress even when stderr is not a TTY
DEEPWIKI_PROGRESS_MODE=plain bun ./scripts/deepwiki.ts query \
  "How does the plugin lifecycle work?" vitejs/vite

# Cap waiting externally if you intentionally want to stop after a while
timeout 8m bun ./scripts/deepwiki.ts query \
  "How does the plugin lifecycle work?" vitejs/vite

# Safer pattern for long deep research: submit, keep the query id, then wait
bun ./scripts/deepwiki.ts start \
  "How does the plugin lifecycle work?" vitejs/vite --mode deep
bun ./scripts/deepwiki.ts wait <query-id>

# Fast-mode fallback before giving up on CLI entirely
bun ./scripts/deepwiki.ts query \
  "What is this repo for?" withastro/starlight --mode fast

# Codemap Mermaid
bun ./scripts/deepwiki.ts query \
  "Show how hooks execute" facebook/react --mode codemap --mermaid > diagram.mmd
```

## Mode 2 — MCP Fallback

Use MCP when the TS client is unavailable or clearly broken.

```json
{
  "mcpServers": {
    "deepwiki": {
      "url": "https://mcp.deepwiki.com/sse"
    }
  }
}
```

Alternate endpoint if SSE fails: `https://mcp.deepwiki.com/mcp`.

### MCP tools

#### `ask_question`

```javascript
mcp__deepwiki__ask_question({
  repoName: "owner/repo",
  question: "How does X work?"
})
```

#### `read_wiki_structure`

Returns the table of contents. Use to survey available documentation before asking.

```javascript
mcp__deepwiki__read_wiki_structure({ repoName: "owner/repo" })
```

#### `read_wiki_contents`

```javascript
mcp__deepwiki__read_wiki_contents({ repoName: "owner/repo", topic: "authentication" })
```

### TS client vs MCP

| Capability | TS client | MCP |
|---|---|---|
| Deep mode | ✅ | ❌ |
| Fast mode | ✅ | ❌ |
| Codemap mode | ✅ | ❌ |
| Multi-repo query | ✅ | ❌ |
| Query resume via `query_id` | ✅ | ❌ |
| Repo index status / warm | ✅ | ❌ |
| Context injection | ✅ | ❌ |
| Source file listing | ✅ | ❌ |

### DeepWiki vs web search

Use DeepWiki when:

- the answer likely lives in a GitHub repo
- the vendor keeps docs in the main repo
- the vendor keeps docs in a separate docs repo
- you need grounded synthesis across source and docs files

Use web search only when:

- you do not yet know the correct official repo
- the answer is not repository-centric
- the vendor documentation is not meaningfully available in GitHub
- DeepWiki cannot access the needed repo or material after reasonable retries

Once you have identified the correct repo, prefer DeepWiki over web search.

If you are unsure whether a repo contains the relevant documentation files, ask DeepWiki directly before concluding that you need a different repo.

## Error Handling

- Repository not found: verify `owner/repo`, check `UPSTREAM_REPOS.md`, inspect the upstream `README.md`, follow repo links to locate the canonical code or docs repo, or do a targeted web search only to discover the correct official repo.
- Service unavailable: if the client gets upstream 502/503/504 failures, retry once or twice, then try the same question with `--mode fast` before falling back to MCP or upstream docs.
- Long-running deep mode: `deep` may legitimately run for a long time. Do not assume a long wait means the query is broken.
- Local timeout: if your shell kills `query`, prefer `start` plus `wait`, or rerun `wait` with the printed `Query-ID`.
- Server-side query timeout: if DeepWiki returns JSON like `{"error":"Query timed out after 240s"}`, treat it as a completed but inconclusive upstream result. Narrow the question, split it, or retry in `fast` mode. Do not blindly rerun the same deep query.
- Courteous usage: batch related questions, reuse `Query-ID` when continuing the same line of investigation, and avoid repeated warm or duplicate deep queries.

## Workflow

```text
1. Check `UPSTREAM_REPOS.md` for the canonical `owner/repo`.

2. If not listed:
   - identify the official GitHub repo first
   - if you are unsure whether the main product repo contains the docs, ask DeepWiki before assuming it does not
   - if the main product repo truly does not contain the docs, look for the official docs repo as well
   - run: `bun ./scripts/deepwiki.ts status owner/repo`
   - if not indexed: `bun ./scripts/deepwiki.ts status owner/repo --warm`

3. Query:
   - prefer `deep` for implementation work and non-trivial documentation research
   - use `fast` if `deep` is unstable or too slow for the current question
   - use `codemap` for architecture and traces

  3.1. For long-running deep work:
    - bun ./scripts/deepwiki.ts start "..." owner/repo
    - bun ./scripts/deepwiki.ts wait <query-id>

4. If the answer raises follow-up questions, thread them using the printed Query-ID:
   bun ./scripts/deepwiki.ts query "..." owner/repo --id <query-id>

5. Write code based on the grounded answer, not on memory.

6. Add the repo to `UPSTREAM_REPOS.md` if it is new to the project and has been successfully validated.

7. Use web search only if you still cannot identify or access the correct repo.
```

## Resolving Repo Names

The client requires exact `owner/repo` format.

1. Check `UPSTREAM_REPOS.md` first.

The project maintains `UPSTREAM_REPOS.md` mapping technologies to their canonical GitHub repo names. Always check it first. If the technology is listed, use the specified `owner/repo` for queries.

2. If not listed:
   - identify the official GitHub repo for the product
   - if you are unsure whether the product repo contains docs, ask DeepWiki before assuming it does not
   - if the product repo truly does not contain docs, identify the official docs repo too
   - use targeted web search only as a repo-discovery step
   - confirm the repo is official
   - run `bun ./scripts/deepwiki.ts status owner/repo`
3. After successful validated use, add it to `UPSTREAM_REPOS.md` if it is new to the project:

```markdown
| Technology | Upstream repo | Use for |
|---|---|---|
| {display name} | {owner}/{repo} | {brief contextual guidance when non-obvious} |
```

## Query Quality

Specific, action-oriented questions produce much better results.

| Vague | Better |
|---|---|
| "How does auth work?" | "What OAuth flows does this library support and how do I configure the callback URL?" |
| "Tell me about plugins" | "What is the lifecycle order of plugin hooks, and which run only during build?" |
| "How do I use this?" | "What is the minimal config needed to serve static files with custom cache headers?" |

Use `--context` when your project constraints materially affect the answer.

## Common Mistakes

| Mistake | Correct behavior |
|---|---|
| Using MCP while the TS client works | Use the TS client first |
| Using web search after the correct repo is already known | Use DeepWiki against the code repo or docs repo |
| Using `fast` for implementation work without trying `deep` | Start with `deep` unless the question is just orientation |
| Treating `Message-ID` as the follow-up identifier | Reuse `Query-ID` with `--id` |
| Killing a long deep query and starting from scratch | Use `start` + `wait` or rerun `wait` with the same `Query-ID` |
| Assuming a repo does not contain docs without checking | Ask DeepWiki whether the repo contains the relevant docs or doc sources |
| Assuming the main repo always contains the docs | Check whether there is a separate official docs repo |
| Guessing repo names | Check `UPSTREAM_REPOS.md`, then verify with `status` |
| Skipping `UPSTREAM_REPOS.md` updates | Add new upstream repos after first successful use |

## Disclaimer

This tool uses reverse-engineered, undocumented `api.devin.ai` endpoints. They may change without notice. If the TS client breaks, fall back to MCP or upstream docs.

In case you can fix the TS client, notify the team and submit a PR. If you cannot, use MCP or read the upstream documentation manually.
