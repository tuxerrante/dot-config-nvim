#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

brew_log="$tmp_dir/brew.log"
brew_bin="$tmp_dir/brew"
cat >"$brew_bin" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BREW_LOG"
case "$1 $2" in
  "list --formula") exit 1 ;;
  "tap hashicorp/tap"|"install "* ) exit 0 ;;
esac
EOF
chmod +x "$brew_bin"

check_output="$(BREW_BIN="$brew_bin" BREW_LOG="$brew_log" "$repo_root/scripts/install-linuxbrew-dependencies.sh" --check)"
grep -Fq "Missing Neovim dependencies:" <<<"$check_output"
grep -Fq "Dry run only." <<<"$check_output"
if grep -Eq '^(tap|install) ' "$brew_log"; then
  echo "error: --check modified Homebrew state" >&2
  exit 1
fi

BREW_BIN="$brew_bin" BREW_LOG="$brew_log" "$repo_root/scripts/install-linuxbrew-dependencies.sh" --apply >/dev/null
grep -Fxq "tap hashicorp/tap" "$brew_log"
grep -Fq "install biome eslint eslint_d" "$brew_log"

echo "Linuxbrew dependency installer tests passed."
