# CopilotChat Review Prep

This repo adds a review-focused context-prep workflow for `CopilotChat.nvim`.

The main entrypoint is:

```vim
:CopilotPrepReview <pr-url>
```

Use `:CopilotPrepReview! <pr-url>` to bypass a fresh cache entry and force a new
collection pass. `!` only affects the collector cache. It does not change repo
matching, worktree selection, switch behavior, or env bootstrap semantics.

## What it does

`CopilotPrepReview` first prepares a review-specific checkout, then collects a
compact context bundle for the first review prompt and opens CopilotChat with
that prompt prefilled so you can edit it before sending.

`CopilotPrepReview` is also a lazy-load command trigger for `CopilotChat.nvim`,
so you do not need to open CopilotChat manually first. A cold start from
`:CopilotPrepReview <pr-url>` is expected to work.

The workflow is intentionally split:

- Lua handles the editor UX and CopilotChat handoff
- `scripts/copilot_prep_review.py` handles deterministic collection and caching

The command does **not** make the prompt sticky globally. It only seeds the
current CopilotChat session.

In normal use, the command now does this:

1. parses the GitHub PR URL
2. validates that the local checkout matches the PR repo
3. creates or reuses `.worktrees/pr-<number>` as a detached review
   checkout
4. switches the current Neovim session into that worktree when it is safe to do
   so
5. symlinks only the explicitly allowlisted env or secret files into the target
   worktree
6. runs the existing Python collector with `--repo-root <target-worktree>`
7. opens CopilotChat with the prepared prompt

Detached HEAD is intentional here. The per-PR worktree is a review workspace,
not a development branch.

## Repo matching and worktrees

Repo selection is deterministic and editor-aware:

- current Neovim cwd is checked first
- loaded file buffers are checked next
- candidate repo `origin` remotes are normalized to `owner/repo`
- the command only proceeds when it can prove the local repo matches the PR repo

If no matching checkout is found, multiple matching checkouts are found, or the
target PR worktree has unexpected local changes, the command stops with a clear
error instead of silently reviewing the wrong checkout.

Review worktrees live under the primary checkout:

```text
.worktrees/pr-<number>
```

If the same PR is prepared again, the detached worktree is reused and updated to
the latest fetched PR head when it is clean.

## Switch safety

The command switches the current Neovim session into the selected review
worktree instead of asking you to open a second instance.

- clean repo-local file buffers switch automatically
- dirty repo-local file buffers prompt with `save-and-switch` or `cancel`
- unsaved changes are never discarded automatically
- non-file buffers and files outside the repo are left alone

When a matching file exists in the target worktree, the same relative path is
reopened from the review checkout and Neovim's cwd is updated to that worktree.

## Env allowlist

Env and secret bootstrap is explicit, symlink-only, and off by default.

```lua
vim.g.copilot_prep_review_env_allowlist = {
  ".env",
  "backend/.env",
  "frontend/.env",
}
```

Rules:

- entries must be repo-relative file paths
- absolute paths, `..` traversal, globs, and directory entries are rejected
- source files come from the primary checkout, not the currently active
  worktree
- missing source files are skipped with a notice instead of failing
- existing matching symlinks are reused
- conflicting target files or mismatched symlinks stop the command with an
  explicit error

## Collection order

The collector prefers deterministic local sources first, then enriches from
remote services when available.

### Local-first inputs

When you run the command from a validated local checkout of the repo under
review, it collects:

- repo docs like `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `README.md`, and
  `CONTRIBUTING.md`
- repo-local `.cursor/rules/**/*.mdc` files when present
- user-level `~/.cursor/rules/*.mdc` files that are either generic review rules
  or explicitly mention the current repo
- validation commands and quality gates inferred from the local `Makefile` plus
  any collected rule excerpts
- domain-context docs by keyword-matching the PR title/body/files against local
  docs and markdown guidance

### Remote enrichment

If `gh` is available and authenticated, the collector also fetches:

- PR metadata
- changed file paths
- prioritized inline review threads, with unresolved threads first and up to 2
  resolved threads kept only when they help avoid repeating already-settled asks
- up to 2 high-signal top-level PR issue comments as secondary context after the
  review-thread summary
- related PRs discoverable from Jira keys in the PR

Conversation enrichment prefers GitHub GraphQL `reviewThreads` via
`gh api graphql` for inline discussion and GitHub issue comments via
`gh api repos/.../issues/.../comments` for top-level PR discussion. If `gh` is
missing, unauthenticated, or either API is unavailable for the repo/PR, the
collector degrades cleanly, keeps any discussion subset that did load, and
records a caveat instead of pretending the full conversation was loaded.

If Jira refs are present, the collector now tries Jira auth/config in this order:

1. current environment
2. `~/.config/.jira_token`
3. `~/.jira_token`

It understands both `JIRA_TOKEN` and `JIRA_API_TOKEN`. For the Jira base URL, it
uses `JIRA_BASE_URL` when set and otherwise derives the site from the Jira link
already present in the PR body. For the Jira user identity, it prefers
`JIRA_EMAIL` / `JIRA_USER` and falls back to `git config --global user.email`.

That means an existing shell setup like:

```zsh
source ~/.config/.jira_token
```

is enough as long as the token file exports `JIRA_API_TOKEN` or `JIRA_TOKEN` and
your global git email matches the Jira account.

When auth succeeds, Jira enrichment includes:

- issue summary/status/type/priority
- parent or epic context when Jira exposes it
- linked Jira cards/issues from the issue links on the primary card

## Handoff behavior

After collection, the command opens CopilotChat and inserts a ready-to-review
prompt containing:

- PR facts
- changed files
- PR diff summary only; the checked-out local worktree is the source of truth for exact hunks
- prior review discussion, kept compact and summary-first, with inline threads
  first and high-signal top-level PR comments only as secondary context
- rules and important docs
- domain context
- quality gates / validation commands
- related PRs
- Jira refs
- degraded-mode caveats

The command finishes by focusing the chat input. With the existing config in
this repo, send it with `<C-j>`.

RTK compaction is not part of the review-prep collector itself. It only applies
later if you use the explicit CopilotChat shell workflow from the opened review
chat: when `rtk` is on your `PATH`, large captured shell-output snapshots are
compacted before they go back into chat; otherwise shell mode falls back
normally and shows the same one-time install hint for the current Neovim
session.

If you want to measure just that post-capture shell-output compaction step, run:

```bash
python3 scripts/benchmark_rtk_shell_review.py
```

Pass one or more quoted commands to benchmark your own review-style shell
queries. Without extra args, the script runs a small built-in review-style
command set against the repo. If `rtk` is missing, the script degrades to
raw-only metrics; use `--require-rtk` if you want that to fail fast instead.

This is intentionally a narrow proxy, not a Copilot billing meter:

- `raw` measures captured command `stdout` before RTK
- `compacted` measures the exact live return payload: trimmed RTK `stderr` plus
  RTK `stdout`
- `tok~` is only a rough `chars / 4` estimate
- it does not measure Copilot billing or full prompt size once the rest of the
  review context is added

On the isolated run that motivated this script, the built-in review command set
reduced total chars by about 31%, and the largest built-in sample
(`rg -n "CopilotChat|rtk|review|shell" README.md docs lua tests scripts`)
reduced chars by about 33%. Treat those numbers as point-in-time examples, not
guarantees: they vary with repo state, command choice, and RTK behavior.

## Cache behavior

Bundles are cached under Neovim's cache dir:

```text
stdpath("cache")/copilot-prep-review
```

The current TTL is 15 minutes per `(repo-root, pr-url)` pair. For
`CopilotPrepReview`, the repo root used for cache identity is the selected PR
worktree root.

If a cached bundle is reused, the prompt now calls out that the review
discussion snapshot may be stale. Use `:CopilotPrepReview!` when you want a
fresh conversation fetch immediately.

## Limitations

- GitHub PR URLs only for now
- review mode only; no general "prep any task" workflow yet
- best results come from running the command with the repo under review already
  open in cwd or loaded buffers
- GitHub enrichment depends on `gh`
- review-thread enrichment also depends on GitHub GraphQL access through `gh`
- Jira enrichment is optional and depends on a usable token plus a resolvable
  Jira user identity
- domain-context matching is heuristic; if nothing relevant matches, the prompt
  says so instead of pretending context was found
- inline review threads are prioritized here, with a small set of high-signal
  top-level PR issue comments added as secondary context; standalone review
  bodies and the rest of the PR conversation are still excluded
