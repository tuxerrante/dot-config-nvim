local M = {}

local async = require("plenary.async")
local runtime = require("copilotchat_runtime")

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

local function make_temp_dir()
  local dir = vim.fn.tempname()
  assert_equal(vim.fn.mkdir(dir, "p"), 1, "failed to create temp dir")
  return dir
end

local function write_file(path, text)
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

local function current_source(cwd)
  return {
    bufnr = vim.api.nvim_get_current_buf(),
    winnr = vim.api.nvim_get_current_win(),
    cwd = function()
      return cwd
    end,
  }
end

local function setup_copilotchat()
  local chat = require("CopilotChat")
  chat.setup({})
  runtime.patch_config()
  return require("CopilotChat.config"), chat
end

local function test_readonly_shell_parser()
  local argv = assert(runtime.split_readonly_command([[cat "foo bar.txt"]]))
  assert_equal(argv, { "cat", "foo bar.txt" }, "quoted readonly command should tokenize safely")

  local ok, output = require("CopilotChat.prompts").execute_tool_call("bash_ro", {
    command = "pwd",
  }, require("CopilotChat.config"), current_source(vim.loop.cwd()))
  assert_truthy(ok, "bash_ro pwd should succeed")
  assert_truthy(output[1] and output[1].data and output[1].data ~= "", "bash_ro should return stdout")

  local rejected = {
    [[find . -delete]],
    [[git branch -D nope]],
    [[git diff --output=oops.patch]],
  }

  for _, command in ipairs(rejected) do
    local split_ok, err = runtime.split_readonly_command(command)
    assert_equal(split_ok, nil, "dangerous readonly command should be rejected")
    assert_truthy(type(err) == "string" and err ~= "", "rejected readonly command should explain why")
  end
end

local function test_edit_autosaves_relative_path()
  local config = require("CopilotChat.config")
  local dir = make_temp_dir()
  local path = dir .. "/sample.txt"

  write_file(path, "old\n")
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  vim.cmd("edit " .. vim.fn.fnameescape(path))

  local diff = table.concat({
    "--- a/sample.txt",
    "+++ b/sample.txt",
    "@@ -1 +1 @@",
    "-old",
    "+new",
  }, "\n")

  config.functions.edit.resolve({
    filename = "sample.txt",
    diff = diff,
  }, current_source(dir))

  local matching = runtime.find_matching_buffer("sample.txt", dir)
  local buffers = vim.tbl_map(function(buf)
    return {
      buf = buf,
      name = vim.api.nvim_buf_get_name(buf),
      loaded = vim.api.nvim_buf_is_loaded(buf),
      modified = vim.bo[buf].modified,
    }
  end, vim.api.nvim_list_bufs())

  assert_equal(read_file(path), "new\n", "edit tool should persist diff to disk\nmatcher: " .. vim.inspect({
    matching = matching,
    current = vim.api.nvim_get_current_buf(),
    buffers = buffers,
  }))
  assert_equal(vim.bo[vim.api.nvim_get_current_buf()].modified, false, "edit tool should leave buffer saved")
end

local function test_accept_diff_autosaves_relative_path(chat)
  local config = require("CopilotChat.config")
  local dir = make_temp_dir()
  local path = dir .. "/sample.txt"
  local original_chat = chat.chat

  write_file(path, "old\n")
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  vim.cmd("edit " .. vim.fn.fnameescape(path))

  chat.chat = {
    get_block = function()
      return {
        header = {
          filename = "sample.txt",
          filetype = "diff",
        },
        content = table.concat({
          "--- a/sample.txt",
          "+++ b/sample.txt",
          "@@ -1 +1 @@",
          "-old",
          "+new",
        }, "\n"),
      }
    end,
  }

  config.mappings.accept_diff.callback(current_source(dir))
  chat.chat = original_chat

  assert_equal(read_file(path), "new\n", "accept_diff should persist diff to disk")
  assert_equal(vim.bo[vim.api.nvim_get_current_buf()].modified, false, "accept_diff should leave buffer saved")
end

function M.run()
  local done = false
  local failure = nil

  async.run(function()
    local ok, err = xpcall(function()
      setup_copilotchat()

      test_readonly_shell_parser()
      test_edit_autosaves_relative_path()
      test_accept_diff_autosaves_relative_path(require("CopilotChat"))
    end, debug.traceback)

    failure = ok and nil or err
    done = true
  end)

  assert_truthy(vim.wait(2000, function()
    return done
  end), "timed out waiting for async CopilotChat tests")

  if failure then
    error(failure)
  end

  print("PASS copilotchat_runtime")
end

return M
