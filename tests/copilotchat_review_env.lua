local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
  end
end

local function assert_truthy(value, message)
  if not value then
    error(message or "expected truthy value")
  end
end

local function assert_nil(value, message)
  if value ~= nil then
    error((message or "expected nil") .. "\nactual: " .. vim.inspect(value))
  end
end

local function assert_match(text, needle, message)
  if type(text) ~= "string" or not string.find(text, needle, 1, true) then
    error((message or "expected match") .. "\nneedle: " .. needle .. "\ntext:\n" .. vim.inspect(text))
  end
end

local function write_file(path, text)
  local parent = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(parent, "p")
  local fd = assert(vim.uv.fs_open(path, "w", 420))
  assert(vim.uv.fs_write(fd, text, 0))
  assert(vim.uv.fs_close(fd))
end

local function test_root()
  return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
end

local function with_temp_dir(prefix, fn)
  local parent = vim.fs.joinpath(test_root(), ".tmp-test-fixtures")
  if not vim.uv.fs_stat(parent) then
    assert_truthy(vim.fn.mkdir(parent, "p") == 1, "failed to create fixture parent " .. parent)
  end

  local root = vim.fs.joinpath(parent, ("%s-%d"):format(prefix, vim.uv.hrtime()))
  assert_truthy(vim.fn.mkdir(root, "p") == 1, "failed to create temp dir " .. root)

  local ok, result = xpcall(function()
    return fn(root)
  end, debug.traceback)

  vim.fn.delete(root, "rf")
  if not ok then
    error(result)
  end

  return result
end

local function readlink(path)
  return assert(vim.uv.fs_readlink(path))
end

local function lstat_type(path)
  local stat = vim.uv.fs_lstat(path)
  return stat and stat.type or nil
end

local function test_validate_allowlist_entry_accepts_repo_relative_file()
  package.loaded.copilotchat_review_env = nil
  local env = require("copilotchat_review_env")

  local ok, err = env.validate_allowlist_entry("backend/.env")
  assert_equal(ok, true, "repo-relative file path should be accepted")
  assert_nil(err, "valid allowlist entry should not return an error")
end

local function test_validate_allowlist_entry_rejects_invalid_entries()
  package.loaded.copilotchat_review_env = nil
  local env = require("copilotchat_review_env")

  local invalid = {
    "",
    "/abs/.env",
    "../.env",
    "config/*.env",
    "secrets/",
  }

  for _, entry in ipairs(invalid) do
    local ok, err = env.validate_allowlist_entry(entry)
    assert_nil(ok, "invalid allowlist entry should be rejected: " .. vim.inspect(entry))
    assert_match(err, "repo-relative file path", "invalid allowlist entry should explain the path constraint")
  end
end

local function test_bootstrap_links_missing_targets_from_primary_root()
  package.loaded.copilotchat_review_env = nil
  local env = require("copilotchat_review_env")

  with_temp_dir("copilot-review-env-link", function(root)
    local primary_root = vim.fs.joinpath(root, "primary")
    local target_root = vim.fs.joinpath(root, "repo", ".worktrees", "pr-123")
    local relpath = "nested/.env"

    write_file(vim.fs.joinpath(primary_root, relpath), "TOKEN=primary\n")

    local result, err = env.bootstrap(primary_root, target_root, { relpath })
    assert_nil(err, "bootstrap should not error for missing target path")
    assert_equal(result, {
      linked = { relpath },
      reused = {},
      skipped_missing = {},
    }, "bootstrap should report a newly linked file")
    assert_equal(lstat_type(vim.fs.joinpath(target_root, relpath)), "link", "target should become a symlink")
    assert_equal(readlink(vim.fs.joinpath(target_root, relpath)), vim.fs.joinpath(primary_root, relpath), "symlink should point back to the primary checkout file")
  end)
end

local function test_bootstrap_skips_missing_source_files()
  package.loaded.copilotchat_review_env = nil
  local env = require("copilotchat_review_env")

  with_temp_dir("copilot-review-env-missing", function(root)
    local primary_root = vim.fs.joinpath(root, "primary")
    local target_root = vim.fs.joinpath(root, "repo", ".worktrees", "pr-123")

    local result, err = env.bootstrap(primary_root, target_root, { ".env" })
    assert_nil(err, "missing source files should not be fatal")
    assert_equal(result, {
      linked = {},
      reused = {},
      skipped_missing = { ".env" },
    }, "bootstrap should record skipped missing source files")
    assert_equal(vim.uv.fs_stat(vim.fs.joinpath(target_root, ".env")), nil, "bootstrap should not create a target entry for missing source files")
  end)
end

local function test_bootstrap_reuses_matching_symlink()
  package.loaded.copilotchat_review_env = nil
  local env = require("copilotchat_review_env")

  with_temp_dir("copilot-review-env-reuse", function(root)
    local primary_root = vim.fs.joinpath(root, "primary")
    local target_root = vim.fs.joinpath(root, "repo", ".worktrees", "pr-123")
    local relpath = ".env"
    local source = vim.fs.joinpath(primary_root, relpath)
    local target = vim.fs.joinpath(target_root, relpath)

    write_file(source, "TOKEN=primary\n")
    vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
    assert_truthy(vim.uv.fs_symlink(source, target), "failed to precreate matching symlink")

    local result, err = env.bootstrap(primary_root, target_root, { relpath })
    assert_nil(err, "matching symlink should be reused")
    assert_equal(result, {
      linked = {},
      reused = { relpath },
      skipped_missing = {},
    }, "bootstrap should report reused matching symlink")
  end)
end

local function test_bootstrap_rejects_conflicting_real_file()
  package.loaded.copilotchat_review_env = nil
  local env = require("copilotchat_review_env")

  with_temp_dir("copilot-review-env-conflict-file", function(root)
    local primary_root = vim.fs.joinpath(root, "primary")
    local target_root = vim.fs.joinpath(root, "repo", ".worktrees", "pr-123")
    local relpath = ".env"

    write_file(vim.fs.joinpath(primary_root, relpath), "TOKEN=primary\n")
    write_file(vim.fs.joinpath(target_root, relpath), "TOKEN=target\n")

    local result, err = env.bootstrap(primary_root, target_root, { relpath })
    assert_nil(result, "real-file conflict should return nil result")
    assert_match(err, "conflict", "real-file conflict should produce an explicit error")
  end)
end

local function test_bootstrap_rejects_conflicting_symlink()
  package.loaded.copilotchat_review_env = nil
  local env = require("copilotchat_review_env")

  with_temp_dir("copilot-review-env-conflict-link", function(root)
    local primary_root = vim.fs.joinpath(root, "primary")
    local other_root = vim.fs.joinpath(root, "other")
    local target_root = vim.fs.joinpath(root, "repo", ".worktrees", "pr-123")
    local relpath = ".env"
    local source = vim.fs.joinpath(primary_root, relpath)
    local other = vim.fs.joinpath(other_root, relpath)
    local target = vim.fs.joinpath(target_root, relpath)

    write_file(source, "TOKEN=primary\n")
    write_file(other, "TOKEN=other\n")
    vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
    assert_truthy(vim.uv.fs_symlink(other, target), "failed to precreate conflicting symlink")

    local result, err = env.bootstrap(primary_root, target_root, { relpath })
    assert_nil(result, "conflicting symlink should return nil result")
    assert_match(err, "conflict", "conflicting symlink should produce an explicit error")
  end)
end

function M.run()
  test_validate_allowlist_entry_accepts_repo_relative_file()
  test_validate_allowlist_entry_rejects_invalid_entries()
  test_bootstrap_links_missing_targets_from_primary_root()
  test_bootstrap_skips_missing_source_files()
  test_bootstrap_reuses_matching_symlink()
  test_bootstrap_rejects_conflicting_real_file()
  test_bootstrap_rejects_conflicting_symlink()
  print("PASS copilotchat_review_env")
end

return M
