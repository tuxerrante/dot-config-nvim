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

local function read_file(path)
  local fd = assert(vim.uv.fs_open(path, "r", 420))
  local stat = assert(vim.uv.fs_fstat(fd))
  local data = assert(vim.uv.fs_read(fd, stat.size, 0))
  assert(vim.uv.fs_close(fd))
  return data
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

local function with_stub(tbl, key, value, fn)
  local original = tbl[key]
  tbl[key] = value
  local ok, result = xpcall(fn, debug.traceback)
  tbl[key] = original
  if not ok then
    error(result)
  end
  return result
end

local function await_result(invoke, timeout_ms)
  local result = nil
  local err = nil
  local done = false

  invoke(function(res, failure)
    result = res
    err = failure
    done = true
  end)

  assert_truthy(vim.wait(timeout_ms or 1000, function()
    return done
  end), "timed out waiting for async switch callback")

  return result, err
end

local function cleanup_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

local function make_switch_fixture(root)
  local source_root = vim.fs.joinpath(root, "repo")
  local target_root = vim.fs.joinpath(source_root, ".worktrees", "pr-123")
  local outside_root = vim.fs.joinpath(root, "outside")

  write_file(vim.fs.joinpath(source_root, "lua", "matched.lua"), "source matched\n")
  write_file(vim.fs.joinpath(source_root, "docs", "missing.md"), "source missing\n")
  write_file(vim.fs.joinpath(target_root, "lua", "matched.lua"), "target matched\n")
  write_file(vim.fs.joinpath(outside_root, "notes.txt"), "outside\n")

  return {
    source_root = source_root,
    target_root = target_root,
    outside_path = vim.fs.joinpath(outside_root, "notes.txt"),
    matched_source = vim.fs.joinpath(source_root, "lua", "matched.lua"),
    matched_target = vim.fs.joinpath(target_root, "lua", "matched.lua"),
    missing_source = vim.fs.joinpath(source_root, "docs", "missing.md"),
  }
end

local function test_clean_switch_reopens_matching_paths_and_skips_missing()
  package.loaded.copilotchat_review_switch = nil
  local switcher = require("copilotchat_review_switch")

  with_temp_dir("copilot-review-switch", function(root)
    local fixture = make_switch_fixture(root)
    cleanup_buffers()

    vim.cmd("cd " .. vim.fn.fnameescape(fixture.source_root))
    vim.cmd("edit " .. vim.fn.fnameescape(fixture.matched_source))
    local matched_buf = vim.api.nvim_get_current_buf()
    vim.cmd("edit " .. vim.fn.fnameescape(fixture.missing_source))
    local missing_buf = vim.api.nvim_get_current_buf()
    vim.cmd("edit " .. vim.fn.fnameescape(fixture.outside_path))
    local outside_buf = vim.api.nvim_get_current_buf()
    vim.cmd("enew")
    local scratch_buf = vim.api.nvim_get_current_buf()

    with_stub(vim.ui, "select", function()
      error("clean switch should not prompt")
    end, function()
      local result, err = switcher.execute(fixture.source_root, fixture.target_root)
      assert_nil(err, "clean switch should not error")
      assert_equal(result, {
        switched_paths = { "lua/matched.lua" },
        skipped_paths = { "docs/missing.md" },
      }, "switch result should report reopened and skipped repo-relative paths")
    end)

    assert_equal(vim.api.nvim_buf_get_name(matched_buf), fixture.matched_target, "matching repo-local file should reopen from target worktree")
    assert_equal(vim.api.nvim_buf_get_name(missing_buf), fixture.missing_source, "repo-local file missing in target should stay on source path")
    assert_equal(vim.api.nvim_buf_get_name(outside_buf), fixture.outside_path, "outside file should remain untouched")
    assert_equal(vim.api.nvim_buf_get_name(scratch_buf), "", "non-file buffer should remain untouched")
    assert_equal(vim.uv.cwd(), fixture.target_root, "cwd should switch to target worktree after remap succeeds")
  end)
end

local function test_dirty_repo_buffer_cancel_keeps_unsaved_edits()
  package.loaded.copilotchat_review_switch = nil
  local switcher = require("copilotchat_review_switch")

  with_temp_dir("copilot-review-switch", function(root)
    local fixture = make_switch_fixture(root)
    cleanup_buffers()

    vim.cmd("cd " .. vim.fn.fnameescape(fixture.source_root))
    vim.cmd("edit " .. vim.fn.fnameescape(fixture.matched_source))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "dirty source edit" })

    local prompt_items = nil
    with_stub(vim.ui, "select", function(items, _, on_choice)
      prompt_items = vim.deepcopy(items)
      vim.schedule(function()
        on_choice("cancel")
      end)
    end, function()
      local original_wait = vim.wait
      local blocked_waits = 0
      vim.wait = function(...)
        blocked_waits = blocked_waits + 1
        return original_wait(...)
      end
      local result, err = await_result(function(on_done)
        switcher.execute(fixture.source_root, fixture.target_root, on_done)
      end)
      vim.wait = original_wait
      assert_nil(result, "cancelled switch should not return a result")
      assert_equal(err, "switch cancelled", "cancelled switch should return a stable error")
      assert_equal(blocked_waits, 1, "only the test harness should wait; dirty buffer switch should stay callback-driven")
    end)

    assert_equal(prompt_items, { "save-and-switch", "cancel" }, "dirty prompt should only offer save-and-switch or cancel")
    assert_equal(vim.api.nvim_buf_get_name(0), fixture.matched_source, "cancelled switch should keep the source buffer open")
    assert_equal(vim.bo[0].modified, true, "cancelled switch should preserve unsaved edits")
    assert_equal(read_file(fixture.matched_source), "source matched\n", "cancelled switch should not write unsaved edits to disk")
    assert_equal(vim.uv.cwd(), fixture.source_root, "cancelled switch should not change cwd")
  end)
end

local function test_dirty_repo_buffer_save_and_switch_writes_source_first()
  package.loaded.copilotchat_review_switch = nil
  local switcher = require("copilotchat_review_switch")

  with_temp_dir("copilot-review-switch", function(root)
    local fixture = make_switch_fixture(root)
    cleanup_buffers()

    vim.cmd("cd " .. vim.fn.fnameescape(fixture.source_root))
    vim.cmd("edit " .. vim.fn.fnameescape(fixture.matched_source))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "saved before switch" })

    with_stub(vim.ui, "select", function(_, _, on_choice)
      vim.schedule(function()
        on_choice("save-and-switch")
      end)
    end, function()
      local original_wait = vim.wait
      local blocked_waits = 0
      vim.wait = function(...)
        blocked_waits = blocked_waits + 1
        return original_wait(...)
      end
      local result, err = await_result(function(on_done)
        switcher.execute(fixture.source_root, fixture.target_root, on_done)
      end)
      vim.wait = original_wait
      assert_nil(err, "save-and-switch should not error")
      assert_equal(result, {
        switched_paths = { "lua/matched.lua" },
        skipped_paths = {},
      }, "save-and-switch should still reopen matching target paths")
      assert_equal(blocked_waits, 1, "only the test harness should wait; save-and-switch should stay callback-driven")
    end)

    assert_equal(read_file(fixture.matched_source), "saved before switch\n", "save-and-switch should preserve unsaved edits by writing the source file")
    assert_equal(vim.api.nvim_buf_get_name(0), fixture.matched_target, "save-and-switch should reopen the target worktree file")
    assert_equal(read_file(fixture.matched_target), "target matched\n", "switch should not overwrite the target worktree file")
    assert_equal(vim.bo[0].modified, false, "reopened target buffer should not remain modified")
  end)
end

function M.run()
  test_clean_switch_reopens_matching_paths_and_skips_missing()
  test_dirty_repo_buffer_cancel_keeps_unsaved_edits()
  test_dirty_repo_buffer_save_and_switch_writes_source_first()
  print("PASS copilotchat_review_switch")
end

return M
