# PR Review Prep

This repo adds a review-focused context-prep workflow that hands its result to
Claude Code through `claudecode.nvim`.

The main entrypoint is:

```vim
:PrepReview <pr-url>
```

Use `:PrepReview! <pr-url>` to bypass a fresh cache entry and force a new
collection pass. `!` only affects the collector cache. It does not change repo
matching, worktree selection, switch behavior, or env bootstrap semantics.

## What it does

`PrepReview` first prepares a review-specific checkout, then collects a
compact context bundle for the first review prompt and pastes it into the Claude
Code terminal without submitting it, so you can edit it before pressing Enter.

`PrepReview` is registered at startup, so you do not need to open Claude Code
first. When no Claude Code session is running, the command starts one, waits for
it to come up and then pastes the prompt. A cold start from
`:PrepReview <pr-url>` is expected to work.

The workflow is intentionally split:

- Lua handles the editor UX and the Claude Code handoff
- `scripts/pr_review_prep.py` handles deterministic collection and caching

The command only seeds the prompt; nothing is made sticky and nothing is sent
until you press Enter.

In normal use, the command now does this:

1. verifies `gh auth status -h github.com`; when it fails, stops and tells you
   to run `gh auth login -h github.com`
2. parses the GitHub PR URL
3. validates that the local checkout matches the PR repo
4. creates or reuses `.worktrees/pr-<number>` as a detached review
   checkout
5. switches the current Neovim session into that worktree when it is safe to do
   so
6. symlinks only the explicitly allowlisted env or secret files into the target
   worktree
7. runs the existing Python collector with `--repo-root <target-worktree>`
8. pastes the prepared prompt into the Claude Code terminal

Detached HEAD is intentional here. The per-PR worktree is a review workspace,
not a development branch. The prepared prompt labels this local state as
`detached HEAD` rather than treating it as a missing branch.

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
vim.g.pr_review_prep_env_allowlist = {
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

After collection, the command pastes a ready-to-review prompt into Claude Code
containing:

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

The paste uses bracketed paste, so the multi-line prompt arrives as one block and
is never submitted by an embedded newline. The Claude Code terminal takes focus
afterwards.

Claude Code reads files relative to the directory it was started in. The review
worktree lives under `.worktrees/` of the primary checkout, so a session started
at the primary checkout can read it; a session started elsewhere will ask for
permission to read the path named in the prompt's `local repo root` fact.

Fallbacks, each reported with a warning notification:

- `claudecode.nvim` is not installed, or its terminal provider runs Claude
  outside Neovim: the prompt is copied to the unnamed register and, when
  available, the system clipboard
- the terminal does not appear within 10 seconds, or its channel is closed: same
  clipboard fallback

Two globals tune the cold start: `vim.g.pr_review_prep_boot_delay_ms` (default
2000, how long to let the TUI start before pasting) and
`vim.g.pr_review_prep_boot_timeout_ms` (default 10000).

## Cache behavior

Bundles are cached under Neovim's cache dir:

```text
stdpath("cache")/pr-review-prep
```

The current TTL is 15 minutes per `(repo-root, pr-url)` pair. For
`PrepReview`, the repo root used for cache identity is the selected PR
worktree root.

If a cached bundle is reused, the prompt now calls out that the review
discussion snapshot may be stale. Use `:PrepReview!` when you want a
fresh conversation fetch immediately.

## Limitations

- GitHub PR URLs only for now
- review mode only; no general "prep any task" workflow yet
- best results come from running the command with the repo under review already
  open in cwd or loaded buffers
- `gh` must be installed and authenticated with `gh auth login -h github.com`
- review-thread enrichment also depends on GitHub GraphQL access through `gh`
- Jira enrichment is optional and depends on a usable token plus a resolvable
  Jira user identity
- domain-context matching is heuristic; if nothing relevant matches, the prompt
  says so instead of pretending context was found
- inline review threads are prioritized here, with a small set of high-signal
  top-level PR issue comments added as secondary context; standalone review
  bodies and the rest of the PR conversation are still excluded
