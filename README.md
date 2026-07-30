# LazyVim for Go + CopilotChat

This repo is my public LazyVim setup, tuned for large Go codebases and a quieter
AI-assisted workflow.

It started from [LazyVim](https://github.com/LazyVim/LazyVim), but the current
customizations focus on:

- Go development on large monorepos and git worktrees
- manual, scoped linting instead of aggressive background `golangci-lint`
- better progress feedback for test runs and custom commands
- a less noisy `CopilotChat.nvim` setup with safer default tool behavior

## Why this setup exists

On big Go repos, the default "run everything all the time" editor behavior can
feel heavy:

- `golangci-lint` on `InsertLeave` is too much
- test commands that run in the background need visible progress
- AI chat needs safe read-only defaults and less wall-of-text output
- worktree-heavy flows benefit from subtle visual cues

This config tries to keep the editor fast while still making the useful bits easy
to trigger on demand.

## Highlights

### Go linting is manual and scoped

`golangci-lint` is removed from the automatic `nvim-lint` loop for Go buffers.
Instead, there is a manual command:

```vim
:GoLint
:GoLint file
:GoLint pkg
:GoLint repo
```

Default scope is `pkg`, so the command is useful on large repos without
accidentally linting everything.

### `gopls` defaults are curated for large repos

The Go LSP config keeps `gopls` enabled but forces a few opinionated defaults:

- `gofumpt`, unimported completion, placeholders, and `staticcheck`
- a small set of extra analyses: `nilness`, `unusedparams`, `unusedwrite`, `useany`
- directory filters that skip `.git`, common editor metadata, and `node_modules`

### Test runs show progress

`neotest` and `GoLint` both surface start/progress/completion notifications,
instead of failing silently while an async command is still running.

For Go tests specifically, `neotest-golang` prefers `gotestsum` when it is
installed and falls back to the standard `go test` runner otherwise.

### CopilotChat is quieter and safer by default

The `CopilotChat.nvim` workflow is split into focused modes:

- default read/review flow
- explicit shell flow
- explicit edit flow
- optional Caveman post-processing flow

The default tool policy prefers safe repo inspection and avoids dumping full file
contents into chat unless needed.

### CopilotChat can prep a PR review prompt

There is a review-focused command for seeding the first CopilotChat prompt from
deterministic repo context plus optional GitHub/Jira enrichment:

```vim
:CopilotPrepReview https://github.com/owner/repo/pull/123
```

Use `:CopilotPrepReview!` to refresh the cached bundle. `!` only affects the
collector cache. It does not change repo matching, worktree selection, switch
behavior, or env bootstrap semantics.

`CopilotPrepReview` now validates the matching local repo, creates or reuses a
detached `.worktrees/pr-<number>` review checkout, safely switches the current
Neovim session into that worktree, bootstraps only explicitly allowlisted env
symlinks, then collects review context against the selected worktree before
opening CopilotChat. The prompt is inserted into the current CopilotChat
session instead of being made globally sticky.

See `docs/copilotchat-review-prep.md` for the exact behavior and limitations.

### Worktree-aware top bar

The top `winbar` is intentionally minimal. It no longer duplicates the lower
breadcrumb/statusline; it just shows the filename and a small `worktree` badge
when the current file is under a git worktree.

## Screenshots

### Scoped Go lint from the current package

<img src="./docs/screenshots/golint-scope.png" alt="GoLint scope selector" width="900" />

### Minimal worktree-aware top bar

<img src="./docs/screenshots/worktree-badge.png" alt="Worktree-aware top bar" width="560" />

### Test progress feedback without opening extra panels

<img src="./docs/screenshots/neotest-progress.png" alt="Neotest progress notification" width="264" />

## Main custom files

If you want to copy ideas instead of the whole config, these are the files worth
reading first:

- `lua/plugins/copilot.lua`
- `lua/copilotchat_runtime.lua`
- `lua/copilotchat_pretty.lua`
- `lua/copilotchat_history.lua`
- `lua/copilotchat_review_prep.lua`
- `scripts/copilot_prep_review.py`
- `lua/plugins/go.lua`
- `lua/plugins/test.lua`
- `lua/plugins/aerial.lua`
- `lua/plugins/typescript.lua`

## Notes for Go developers

This repo assumes you already have a working Go toolchain. The nicest experience
comes from having these available on your machine:

- `go`
- `gopls`
- `golangci-lint`
- `goimports`
- `gofumpt`
- `gotestsum` (optional; used automatically by `neotest-golang` when available)

## Install

If you want to try the full setup:

```bash
git clone https://github.com/tuxerrante/dot-config-nvim ~/.config/nvim
nvim
```

LazyVim will handle plugin bootstrap on first launch.
