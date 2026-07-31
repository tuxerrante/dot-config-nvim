#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
nvim_bin="${NVIM_BIN:-nvim}"
python_bin="${PYTHON_BIN:-python3}"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/dot-config-nvim-test.XXXXXX")"
config_root="$tmp_root/xdg-config/nvim"

cleanup() {
  rm -rf "$tmp_root"
}

trap cleanup EXIT

if ! command -v "$nvim_bin" >/dev/null 2>&1; then
  echo "error: Neovim binary not found: $nvim_bin" >&2
  exit 1
fi

if ! command -v "$python_bin" >/dev/null 2>&1; then
  echo "error: Python binary not found: $python_bin" >&2
  exit 1
fi

export XDG_CONFIG_HOME="$tmp_root/xdg-config"
export XDG_DATA_HOME="$tmp_root/xdg-data"
export XDG_STATE_HOME="$tmp_root/xdg-state"
export XDG_CACHE_HOME="$tmp_root/xdg-cache"

mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

"$python_bin" - "$repo_root" "$config_root" <<'PY'
import shutil
import sys

src, dst = sys.argv[1], sys.argv[2]
shutil.copytree(
    src,
    dst,
    symlinks=True,
    dirs_exist_ok=True,
    ignore=shutil.ignore_patterns(".git", ".worktrees", "__pycache__"),
)
PY

run_lua_test() {
  local module="$1"

  echo "Running $module..."
  (
    cd "$config_root"
    "$nvim_bin" --headless -u tests/minimal_init.lua \
      -c "lua local ok, mod = pcall(require, '$module'); if not ok then vim.api.nvim_err_writeln(mod); vim.cmd('cquit 1') end; local ok_run, err = xpcall(mod.run, debug.traceback); if not ok_run then vim.api.nvim_err_writeln(err); vim.cmd('cquit 1') end; vim.cmd('qa')"
  )
}

echo "Restoring plugins in disposable XDG dirs..."
(
  cd "$config_root"
  "$nvim_bin" --headless "+Lazy! restore" +qa
)

echo "Running Python tests..."
(
  cd "$config_root"
  "$python_bin" -m unittest tests.test_copilot_prep_review
)

run_lua_test "tests.copilot_plugin_spec"
run_lua_test "tests.copilotchat_runtime"
run_lua_test "tests.copilotchat_review_env"
run_lua_test "tests.copilotchat_review_repo"
run_lua_test "tests.copilotchat_review_switch"
run_lua_test "tests.copilotchat_review_prep"

echo "All disposable-environment tests passed."
