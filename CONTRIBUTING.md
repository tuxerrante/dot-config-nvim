# Contributing

Thanks for taking a look at this Neovim config.

This repo is public and contributions are welcome, but changes should stay
focused and easy to validate. The main branch is intended to move through pull
requests, not ad-hoc direct pushes.

## Ground Rules

- Keep changes scoped to one problem or workflow improvement.
- Update docs or screenshots when behavior changes in a user-visible way.
- Include the validation command you ran in the PR description.
- Do not test untrusted pull request code by pointing your live
  `~/.config/nvim` at that branch.

## Local Validation

Run the contributor test workflow from the checked-out repo root:

```bash
bash scripts/test-in-disposable-env.sh
```

What the script does:

- creates temporary `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, and
  `XDG_CACHE_HOME` directories
- copies the checked-out repo into a disposable `nvim` config directory
- bootstraps plugins into the temporary data directory
- runs the Python and headless Neovim tests

That keeps the test run out of your daily-driver Neovim profile. The first run
needs network access so Lazy can install plugins into the temporary data dir.

## Safe Workflow For External PRs

If you are reviewing untrusted code from an external contributor, use both a
disposable checkout and the disposable test script.

Example maintainer flow with `gh`:

```bash
tmpdir="$(mktemp -d)"
gh repo clone tuxerrante/dot-config-nvim "$tmpdir/dot-config-nvim"
cd "$tmpdir/dot-config-nvim"
gh pr checkout 123 --detach
bash scripts/test-in-disposable-env.sh
```

Replace `123` with the pull request number, then delete the temporary checkout
when you are done reviewing.

Do not:

- replace your live `~/.config/nvim` with an external PR branch
- reuse your normal `XDG_*` Neovim directories for untrusted PR code
- copy personal secrets or env files into an external contributor checkout

If you prefer worktrees over a disposable clone, the same rule still applies:
test the PR from a dedicated review worktree and keep the Neovim runtime/data
directories disposable.

## Pull Request Notes

Please include:

- a short summary of the problem and the chosen fix
- the validation command you ran
- any plugin bootstrap, shell-command, or security-sensitive behavior changes

If the change touches shell integrations, repo inspection helpers, or anything
that might run against untrusted code, call that out explicitly in the PR.

## Security Reports

Please do not open public issues for vulnerabilities. Use GitHub private
vulnerability reporting as described in `SECURITY.md`.
