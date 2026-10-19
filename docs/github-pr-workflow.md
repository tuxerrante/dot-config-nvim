# GitHub PR Workflow

Reviewing and answering PR comments without leaving Neovim, and moving between
worktrees without losing track of what each one points at.

Two pieces:

- [octo.nvim](https://github.com/pwntester/octo.nvim), enabled through the
  `lazyvim.plugins.extras.util.octo` extra, for the GitHub side
- `lua/worktree.lua`, for the worktree badge and the worktree picker

`<localleader>` is `\` in this config, so `<localleader>ca` is typed `\ca`.

## Requirements

`gh` must be installed and authenticated, same as `:PrepReview`:

```bash
gh auth status -h github.com   # or: gh auth login -h github.com
```

Run `:Lazy sync` once to install `octo.nvim`, then `:checkhealth octo`.

`lua/plugins/octo.lua` sets `default_to_projects_v2 = false`, overriding the
LazyVim extra. Octo checks for the `read:project` scope before adding the
ProjectsV2 *query* fragment, but its ProjectsV2 *timeline* fragments are gated
on that flag alone, so a token without the scope fails with "The 'status' field
requires one of the following scopes: ['read:project']" the moment a PR
timeline is drawn. To get those timeline events back:

```bash
gh auth refresh -h github.com -s read:project
```

then flip the flag to `true`.

## Entry points

| Keys | What it does |
| --- | --- |
| `<leader>gv` | the PR conversation for this worktree, comments and all |
| `<leader>gV` | the same PR as a three-pane review diff |
| `<leader>gp` | list open PRs for this repo |
| `<leader>gP` | search PRs |
| `<leader>gi` / `<leader>gI` | list / search issues |
| `<leader>gw` | switch to another worktree of this repo |
| `<leader>gr` | list repos |

In the PR picker, `<C-o>` checks the PR out, `<C-b>` opens it in the browser,
`<C-y>` copies its URL.

### Detached worktrees

Both keys normally work out which PR you mean from the current branch's
upstream. That fails in the detached `.worktrees/pr-<number>` checkouts
`:PrepReview` creates, because there is no branch to ask about.

So they resolve the PR number first, in this order:

1. the worktree directory name, if it looks like `.worktrees/pr-<number>`
   (`pr-1402-kyverno-3.x` counts, the trailing text is ignored)
2. `gh pr view` for the current branch
3. failing both, it falls back to the PR list

## Answering comments on your own PR

This is the common case, and it does **not** need the review diff at all.

`<leader>gv` opens the PR as a single scrollable buffer: description, timeline,
and every review thread rendered inline underneath, each with its own header:

```text
THREAD: .github/workflows/publish-charts-reusable.yml 1:1 [Commit: 8d210c22]
THREAD COMMENT: schrodit 2 hours ago
wondering why this is a workflow. Might be more readable when it's an
action, then people directly know that it's used in workflows.
```

The header carries the file and line range, plus `OUTDATED` and `RESOLVED`
markers when they apply. Everything is in one document, so nothing appears or
disappears as you move.

| Keys | What it does |
| --- | --- |
| `]t` / `[t` | next / previous review **thread**, wrapping around |
| `<localleader>T` | pick a thread from a list |
| `]c` / `[c` | next / previous comment — walks **every** comment in the PR |
| `<cr>` | open the file at the line the thread comments on |
| `<localleader>cr` | reply to the thread under the cursor |
| `<localleader>rt` / `<localleader>rT` | resolve / unresolve it |
| `gf` | octo's own version of `<cr>`, without the bounds check |
| `<localleader>o` | PR action menu (checkout, merge, close, …) |
| `<localleader>ca` | comment on the PR itself |
| `<C-r>` | reload the PR |
| `<C-b>` | open it in the browser |

The buffer opens at the top, on the description, and threads are rendered
*after* the whole timeline — so on a PR with a long description and a Copilot
review, the comments you came for are several screens down. `]t` goes straight
to the first one, wrapping around at the end, and echoes where you landed:

```text
thread 2/7  ● .github/workflows/publish-charts-reusable.yml:1  2 comments  schrodit: wondering why this is a workflow
```

`<localleader>T` (`\T`) lists them all in the picker instead, with `✓` for
resolved, `outdated` where it applies, and the first comment as the summary.
Both open the fold when the thread is collapsed, and scroll so the `THREAD:`
header stays visible.

`<cr>` on a thread edits the file it points at and puts the cursor on the
commented line; `<c-o>` comes back to the PR. Outdated threads still carry
their original line, which may be past the end of the file by now, so the line
is clamped instead of throwing the way octo's `gf` does.

Octo binds `<cr>` to a 44-entry PR action menu whose top entries include "Close
PR", "Squash and Merge" and "Update Base Branch" — irreversible things one
keystroke away from the key you press to follow something. `lua/plugins/octo.lua`
moves that menu to `<localleader>o` (`\o`) and leaves `<cr>` for navigation.

None of these are octo defaults — `lua/octo_threads.lua` reads the
extmarks octo leaves around each thread region. `]t` / `[t` are deliberately
the same keys octo already uses for threads inside the review diff.

Replies are ordinary buffer text: type the body, then `:w` posts it.

Note that `<localleader>cr` is two keystrokes after the localleader — `\`,
then `cr`. Typing `cr` on its own is `c` (change) plus flash.nvim's `r`
(Remote Flash), which is why it looks like nothing related to octo happened.

## Reviewing someone else's changes

`<leader>gV` runs `Octo review browse`, which loads every thread into a diff
layout without touching GitHub. To add *new* review comments you first need a
pending review: `:Octo review start` from inside the layout upgrades the
review octo is already holding (it calls `addPullRequestReview`, so it does
create a draft review on GitHub).

In the **file panel**:

| Keys | What it does |
| --- | --- |
| `j` / `k` | next / previous changed file |
| `<cr>` | open the diff for that file (the Enter key) |
| `R` | refresh the file list |
| `<localleader><space>` | toggle "viewed" for the file |
| `<localleader>b` | hide/show the panel |

In the **diff**:

| Keys | What it does |
| --- | --- |
| `<localleader>ca` | add a review comment (works in visual mode for a range) |
| `<localleader>sa` | add a suggestion |
| `]t` / `[t` | next / previous existing thread |
| `]q` / `[q` | next / previous changed file |
| `]u` / `[u` | next / previous *unviewed* file |
| `<localleader>e` | jump focus back to the file panel |
| `<localleader>C` | review commit by commit instead of the whole diff |
| `<localleader>t` | open the thread under the cursor and jump into it |

Comments only ever appear in the **right-hand** diff window, on the PR's
version of the file, marked with virtual text at the end of the line
(`▎2 comments  3d`). The line itself is not highlighted.

`lua/plugins/octo.lua` sets `reviews.auto_show_threads = false`. With octo's
default of `true`, moving the cursor onto a commented line replaces the *base*
diff window with the thread and moving off swaps it back, so threads flash in
and out as you scroll and you can never get into one to reply. Instead, put the
cursor on the line and press `<localleader>t`, which renders the thread and
moves you into it, where it stays. `q` closes it and returns you to the diff.

`<localleader>t` is not an octo default; it is added by a `BufWinEnter` hook in
`lua/plugins/octo.lua`, because review diff buffers keep the reviewed file's
own filetype (`yaml`, `sh`, …) and so have no `FileType` event to hang a
mapping on.

In a **thread**:

| Keys | What it does |
| --- | --- |
| `<localleader>cr` | reply |
| `<localleader>ca` | add a comment |
| `<localleader>cd` | delete your comment |
| `<localleader>rt` / `<localleader>rT` | resolve / unresolve the thread |
| `<localleader>r+` `<localleader>r-` `<localleader>rh` … | reactions |

Comments are ordinary buffers: type the body, then `:w` sends it to GitHub.
Editing an existing comment and saving updates it.

## Submitting

From the diff or the file panel:

| Keys | What it does |
| --- | --- |
| `<localleader>vs` | submit the review |
| `<localleader>vd` | discard the pending review |
| `<C-c>` | close the review tab |

`<localleader>vs` opens a float for the summary. Write it, leave insert mode,
then:

| Keys | What it does |
| --- | --- |
| `<C-a>` | approve |
| `<C-r>` | request changes |
| `<C-m>` | comment |
| `<C-c>` | cancel |

Useful commands alongside those: `:Octo review comments` lists your pending
comments, `:Octo review resume` picks a pending review back up, and
`:Octo review discard` throws it away.

Note that `<localleader>vs` means **start a review** in a PR buffer and
**submit the review** once you are inside the review diff.

## The worktree badge

The `winbar` shows a badge when the current file is under a `.worktrees/`
directory. It answers "which worktree is this, and where does it point":

```text
🌿 publish-charts-refactor → origin
🌿 renovate/kyverno-3.x → origin ↓23 #1402
🌿 ci/pre-commit-lint → origin ↑2↓5
🌿 fix/bom-generation ⚠ no upstream
🌿 PR #1445 detached @a107ba3a
```

Reading it:

- the first field is the checked-out branch, not the directory name
- `→ origin` means the upstream is `origin/<same name>`; a drifted name is
  spelled out in full, as in `→ origin/other-name`
- `↑` is commits you have that the upstream does not, `↓` is the reverse
- `⚠ no upstream` means nothing has been pushed yet
- a trailing `#1402` is the PR number inferred from the directory name

The main checkout deliberately has no badge — the statusline already shows its
branch, and the badge exists to tell worktrees apart. To show it everywhere,
drop the `cond` from the `worktree_component` in `lua/plugins/aerial.lua`.

State is cached per worktree, and refreshed on focus changes, `:cd`, and when a
terminal job exits (so committing or pushing in lazygit updates it). Use
`:WorktreeRefresh` if it ever looks stale.

## Switching worktrees

`<leader>gw` (or `:WorktreePick`) lists every worktree of the current repo with
the same branch/upstream detail as the badge:

```text
   charts                   chore/argocd-redis-dockerhub-mirror → origin
   ci-untrack-sboms         ci/untrack-sboms → origin
   pr-1402-kyverno-3.x      renovate/kyverno-3.x → origin ↓23 #1402
 ● publish-charts-refactor  publish-charts-refactor → origin
```

`●` marks where you are. Picking one reuses the same switch logic as
`:PrepReview` (`lua/review_switch.lua`): repo-local buffers
are reopened at the same relative path in the target worktree, modified buffers
prompt for `save-and-switch` first, and the session's cwd follows. Buffers with
no counterpart in the target are reported and left alone.

Worktrees registered in git but gone from disk are listed as
`⚠ missing on disk`; clean them up with `git worktree prune`.

## Limitations

- `<leader>gv` resolves the PR number synchronously, so the `gh pr view`
  fallback costs a network round trip on branches whose PR is not encoded in
  the directory name
- the badge only appears under `.worktrees/`; worktrees kept elsewhere (say
  `codesphere/fix/bom-generation`) are pickable but not badged
- `octo.nvim` talks to GitHub directly, so the review always reflects the
  remote PR, not the `:PrepReview` cached bundle
