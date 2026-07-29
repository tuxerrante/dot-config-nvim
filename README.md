# LazyVim for Go + CopilotChat

This repo is my public LazyVim setup, tuned for large Go codebases and a quieter
AI-assisted workflow.

It started from [LazyVim](https://github.com/LazyVim/LazyVim), but the Go
customizations focus on keeping large repositories responsive while preserving
useful defaults.

## Go highlights

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

### Go tests prefer `gotestsum` when available

`neotest` and `GoLint` both surface start/progress/completion notifications.
For Go tests specifically, `neotest-golang` prefers `gotestsum` when it is
installed and falls back to the standard `go test` runner otherwise.

## Main custom files

If you want to copy ideas instead of the whole config, these are the files worth
reading first:

- `lua/plugins/go.lua`
- `lua/plugins/test.lua`

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
