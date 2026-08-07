#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [--check | --apply]" >&2
  exit 2
}

mode="check"
while (($#)); do
  case "$1" in
    --check) mode="check" ;;
    --apply) mode="apply" ;;
    *) usage ;;
  esac
  shift
done

if [[ -n "${BREW_BIN:-}" ]]; then
  brew_bin="$BREW_BIN"
elif command -v brew >/dev/null 2>&1; then
  brew_bin="$(command -v brew)"
elif [[ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
  brew_bin="/home/linuxbrew/.linuxbrew/bin/brew"
else
  echo "error: Homebrew is not installed or on PATH." >&2
  exit 1
fi

formulae=(
  biome
  eslint
  eslint_d
  fish
  go
  gofumpt
  goimports
  golangci-lint
  gopls
  gotestsum
  hadolint
  hashicorp/tap/terraform
  markdown-toc
  markdownlint-cli2
  nixfmt
  prettier
  rtk
  shellcheck
  shfmt
  statix
  stylua
  tree-sitter-cli
)

missing=()
for formula in "${formulae[@]}"; do
  if ! "$brew_bin" list --formula "$formula" >/dev/null 2>&1; then
    missing+=("$formula")
  fi
done

if ((${#missing[@]} == 0)); then
  echo "All Neovim dependencies are installed."
  exit 0
fi

echo "Missing Neovim dependencies:"
printf '  %s\n' "${missing[@]}"

if [[ "$mode" == "check" ]]; then
  echo "Dry run only. Re-run with: $0 --apply"
  exit 0
fi

if [[ " ${missing[*]} " == *" hashicorp/tap/terraform "* ]]; then
  "$brew_bin" tap hashicorp/tap
fi

"$brew_bin" install "${missing[@]}"
