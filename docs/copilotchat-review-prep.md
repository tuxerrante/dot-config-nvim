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
- prioritized inline review threads and comments, with unresolved threads first and
  up to 2 resolved threads kept only when they help avoid repeating already-settled asks
- related PRs discoverable from Jira keys in the PR

Review-thread enrichment prefers GitHub GraphQL `reviewThreads` via `gh api graphql`.
If `gh` is missing, unauthenticated, or GraphQL thread data is unavailable for the
repo/PR, the collector degrades cleanly, omits the section, and records a caveat
instead of pretending reviewer discussion was loaded.

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
- prior review discussion, kept compact and summary-first
- rules and important docs
- domain context
- quality gates / validation commands
- related PRs
- Jira refs
- degraded-mode caveats

The command finishes by focusing the chat input. With the existing config in
this repo, send it with `<C-j>`.

## Cache behavior

Bundles are cached under Neovim's cache dir:

```text
stdpath("cache")/copilot-prep-review
```

The current TTL is 15 minutes per `(repo-root, pr-url)` pair. For
`CopilotPrepReview`, the repo root used for cache identity is the selected PR
worktree root.

If a cached bundle is reused, the prompt now calls out that the review-thread
snapshot may be stale. Use `:CopilotPrepReview!` when you want a fresh
conversation fetch immediately.

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
- only inline review threads are preloaded here; general PR conversation,
  standalone review bodies, and non-review issue comments are still excluded
