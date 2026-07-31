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

local function assert_contains(list, value, message)
  assert_truthy(vim.tbl_contains(list, value), message or ("expected list to contain " .. value))
end

local function assert_not_contains(list, value, message)
  assert_truthy(not vim.tbl_contains(list, value), message or ("expected list to exclude " .. value))
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

local function shell_source(cwd)
  return {
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

local function test_tool_sets_keep_shell_policy_explicit()
  assert_contains(runtime.DEFAULT_TOOLS, "grep", "default tools should keep the structured grep tool available")
  assert_not_contains(runtime.DEFAULT_TOOLS, "bash_safe", "default tools should not expose bash_safe implicitly")
  assert_contains(runtime.DEFAULT_TRUSTED_TOOLS, "grep", "default trusted tools should keep workspace grep trusted")
  assert_not_contains(runtime.DEFAULT_TRUSTED_TOOLS, "bash_safe", "default trusted tools should not trust bash_safe implicitly")

  assert_contains(runtime.EDIT_TOOLS, "edit", "edit workflow should expose edit")
  assert_not_contains(runtime.EDIT_TOOLS, "bash_safe", "edit workflow should not expose bash_safe implicitly")
  assert_not_contains(runtime.EDIT_TRUSTED_TOOLS, "edit", "edit workflow should still require approval for edits")
  assert_not_contains(runtime.EDIT_TRUSTED_TOOLS, "bash_safe", "edit workflow should not trust bash_safe implicitly")

  assert_contains(runtime.SHELL_TOOLS, "bash_safe", "shell workflow should expose bash_safe")
  assert_contains(runtime.SHELL_TOOLS, "bash", "shell workflow should still expose unrestricted bash")
  assert_contains(runtime.SHELL_TRUSTED_TOOLS, "bash_safe", "shell workflow should trust bash_safe")
  assert_not_contains(runtime.SHELL_TRUSTED_TOOLS, "bash", "shell workflow should keep unrestricted bash gated")
end

local function test_readonly_shell_parser()
  runtime._reset_rtk_state_for_tests()
  runtime._set_rtk_path_for_tests(nil)
  runtime._set_rtk_missing_notified_for_tests(true)

  local argv = assert(runtime.split_safe_command([[cat "foo bar.txt"]]))
  assert_equal(argv, { "cat", "foo bar.txt" }, "quoted readonly command should tokenize safely")

  local trusted_grep = assert(runtime.split_safe_command(
    [[grep -A25 'type CapacityReservationGroup struct' /Users/alessandroaffinito/go/pkg/mod/example/models.go]]
  ))
  assert_equal(
    trusted_grep,
    {
      "grep",
      "-A25",
      "type CapacityReservationGroup struct",
      "/Users/alessandroaffinito/go/pkg/mod/example/models.go",
    },
    "trusted grep command should allow quoted patterns and absolute paths"
  )

  with_stub(vim, "notify", function() end, function()
    local ok, output = require("CopilotChat.prompts").execute_tool_call("bash_ro", {
      command = "pwd",
    }, require("CopilotChat.config"), current_source(vim.loop.cwd()))
    assert_truthy(ok, "bash_ro pwd should succeed")
    assert_truthy(output[1] and output[1].data and output[1].data ~= "", "bash_ro should return stdout")
  end)

  local rejected = {
    [[find . -delete]],
    [[git branch -D nope]],
    [[git diff --output=oops.patch]],
  }

  for _, command in ipairs(rejected) do
    local split_ok, err = runtime.split_safe_command(command)
    assert_equal(split_ok, nil, "dangerous readonly command should be rejected")
    assert_truthy(type(err) == "string" and err ~= "", "rejected readonly command should explain why")
  end

  local shell_only, shell_only_err = runtime.split_safe_command([[grep -n "func main" $(go env GOPATH)/src/example/main.go]])
  assert_equal(shell_only, nil, "shell-only command substitution should be rejected in readonly shell mode")
  assert_truthy(
    type(shell_only_err) == "string" and shell_only_err:match("shell"),
    "shell-only syntax rejection should explain that bash_safe does not invoke a shell"
  )

  local allowed_make_targets = {
    "make fmt",
    "make lint-go",
    "make unit-test-go",
    "make test-go",
    "make validate-imports",
    "make validate-gh-actions",
    "make validate-go",
    "make validate-go-action",
    "make go-verify",
  }

  for _, command in ipairs(allowed_make_targets) do
    local make_argv = assert(runtime.split_safe_command(command))
    assert_equal(make_argv, vim.split(command, " "), "trusted make target should be allowed: " .. command)
  end

  local rejected_make_targets = {
    "make lint-go-fix",
    "make generate",
    "make build-all",
    "make test-e2e",
  }

  for _, command in ipairs(rejected_make_targets) do
    local make_argv, make_err = runtime.split_safe_command(command)
    assert_equal(make_argv, nil, "non-allowlisted make target should be rejected: " .. command)
    assert_truthy(type(make_err) == "string" and make_err:match("make"), "rejected make target should explain why")
  end
end

local function test_readonly_shell_uses_async_system_wrapper()
  local config = require("CopilotChat.config")
  local calls = {}
  runtime._reset_rtk_state_for_tests()
  runtime._set_rtk_path_for_tests(nil)
  runtime._set_rtk_missing_notified_for_tests(true)

  with_stub(vim, "notify", function() end, function()
    with_stub(vim, "system", function(cmd, opts, callback)
      table.insert(calls, {
        cmd = vim.deepcopy(cmd),
        opts = vim.deepcopy(opts),
        callback_type = type(callback),
      })

      assert_equal(type(callback), "function", "bash_safe should use callback-style vim.system")
      callback({
        code = 0,
        stdout = "async-ok\n",
        stderr = "",
      })

      return {
        wait = function()
          error("bash_safe should not call :wait() directly")
        end,
      }
    end, function()
      local ok, output = require("CopilotChat.prompts").execute_tool_call("bash_ro", {
        command = "pwd",
      }, config, {
        cwd = function()
          return vim.loop.cwd()
        end,
      })

      assert_truthy(ok, "bash_ro should succeed through CopilotChat utils.system")
      assert_equal(output[1].data, "async-ok\n", "bash_ro should return async command stdout")
    end)
  end)

  assert_equal(#calls, 1, "bash_safe should execute exactly one system call")
end

local function test_rtk_compacts_shell_output_when_available()
  local config = require("CopilotChat.config")
  local calls = {}
  local notify_calls = {}
  runtime._reset_rtk_state_for_tests()
  runtime._set_rtk_path_for_tests("/tmp/fake-rtk")

  with_stub(vim, "notify", function(message, level, opts)
    table.insert(notify_calls, {
      message = message,
      level = level,
      opts = opts,
    })
  end, function()
    with_stub(vim, "system", function(cmd, opts, callback)
      table.insert(calls, {
        cmd = vim.deepcopy(cmd),
        opts = vim.deepcopy(opts),
        callback_type = type(callback),
      })

      if #calls == 1 then
        assert_equal(type(callback), "function", "bash_ro should still execute the underlying command asynchronously")
        callback({
          code = 0,
          stdout = "trusted shell output\n",
          stderr = "",
        })
      elseif #calls == 2 then
        assert_equal(callback, nil, "RTK compaction should run as a synchronous post-processing step")
        assert_equal(cmd[1], "/tmp/fake-rtk", "bash_ro should compact through the detected rtk binary")
        assert_equal(cmd[2], "cat", "bash_ro should ask rtk to compact a temp file snapshot")
        return {
          wait = function()
            return {
              code = 0,
              stdout = "--- HEAD (180 lines) ---\ntrusted shell output\n",
              stderr = "[rtk] original lines: 999; emitting compressed snapshot\n",
            }
          end,
        }
      elseif #calls == 3 then
        assert_equal(type(callback), "function", "bash should still execute the underlying command asynchronously")
        callback({
          code = 0,
          stdout = "unrestricted shell output\n",
          stderr = "",
        })
      elseif #calls == 4 then
        assert_equal(callback, nil, "RTK compaction should run as a synchronous post-processing step")
        assert_equal(cmd[1], "/tmp/fake-rtk", "bash should reuse the detected rtk binary")
        assert_equal(cmd[2], "cat", "bash should compact the captured stdout through rtk")
        return {
          wait = function()
            return {
              code = 0,
              stdout = "--- HEAD (180 lines) ---\nunrestricted shell output\n",
              stderr = "",
            }
          end,
        }
      else
        error("unexpected vim.system call count: " .. tostring(#calls))
      end

      return {
        wait = function()
          error("shell tool tests should not call :wait() directly")
        end,
      }
    end, function()
      local output_ro = config.functions.bash_safe.resolve({
        command = "pwd",
      }, shell_source(vim.loop.cwd()))
      assert_equal(
        output_ro[1].data,
        "[rtk] original lines: 999; emitting compressed snapshot\n--- HEAD (180 lines) ---\ntrusted shell output\n",
        "bash_ro should return the RTK-compacted snapshot"
      )

      local output_bash = config.functions.bash.resolve({
        command = "printf test",
      }, shell_source(vim.loop.cwd()))
      assert_equal(
        output_bash[1].data,
        "--- HEAD (180 lines) ---\nunrestricted shell output\n",
        "bash should also return the RTK-compacted snapshot"
      )
    end)
  end)

  assert_equal(#calls, 4, "RTK-present shell calls should execute the command and one RTK compaction pass per tool call")
  assert_equal(#notify_calls, 0, "RTK-present shell calls should not show the missing-RTK banner")
end

local function test_rtk_missing_falls_back_to_plain_shell_output()
  local config = require("CopilotChat.config")
  local calls = {}
  local notify_calls = {}
  runtime._reset_rtk_state_for_tests()
  runtime._set_rtk_path_for_tests(nil)

  with_stub(vim, "notify", function(message, level, opts)
    table.insert(notify_calls, {
      message = message,
      level = level,
      opts = opts,
    })
  end, function()
    with_stub(vim, "system", function(cmd, opts, callback)
      table.insert(calls, {
        cmd = vim.deepcopy(cmd),
        opts = vim.deepcopy(opts),
        callback_type = type(callback),
      })

      assert_equal(type(callback), "function", "missing RTK should not change the main shell execution mode")
      callback({
        code = 0,
        stdout = "plain trusted output\n",
        stderr = "",
      })

      return {
        wait = function()
          error("shell tool tests should not call :wait() directly")
        end,
      }
    end, function()
      local output = config.functions.bash_safe.resolve({
        command = "pwd",
      }, shell_source(vim.loop.cwd()))
      assert_equal(output[1].data, "plain trusted output\n", "missing RTK should fall back to the original shell output")
      require("CopilotChat.utils").schedule_main()
      assert_truthy(#notify_calls > 0, "missing RTK notice should be delivered while the stub is active")
    end)
  end)

  assert_equal(#calls, 1, "missing RTK should not add a second compaction system call")
  assert_equal(#notify_calls, 1, "missing RTK should show one informational banner on first shell use")
  assert_truthy(
    type(notify_calls[1].message) == "string" and string.find(notify_calls[1].message, "`rtk`", 1, true),
    "missing RTK banner should mention the optional rtk install"
  )
end

local function test_rtk_missing_banner_only_notifies_once_per_session()
  local config = require("CopilotChat.config")
  local notify_calls = {}
  runtime._reset_rtk_state_for_tests()
  runtime._set_rtk_path_for_tests(nil)

  with_stub(vim, "notify", function(message, level, opts)
    table.insert(notify_calls, {
      message = message,
      level = level,
      opts = opts,
    })
  end, function()
    with_stub(vim, "system", function(_, _, callback)
      assert_equal(type(callback), "function", "missing RTK should keep shell execution on the async vim.system path")
      callback({
        code = 0,
        stdout = "plain output\n",
        stderr = "",
      })
      return {
        wait = function()
          error("shell tool tests should not call :wait() directly")
        end,
      }
    end, function()
      local output_ro = config.functions.bash_safe.resolve({
        command = "pwd",
      }, shell_source(vim.loop.cwd()))
      local output_bash = config.functions.bash.resolve({
        command = "printf test",
      }, shell_source(vim.loop.cwd()))
      assert_equal(output_ro[1].data, "plain output\n", "first missing-RTK shell call should still fall back cleanly")
      assert_equal(output_bash[1].data, "plain output\n", "second missing-RTK shell call should still fall back cleanly")
      require("CopilotChat.utils").schedule_main()
      assert_truthy(#notify_calls > 0, "missing RTK banner should be delivered while the stub is active")
    end)
  end)

  assert_equal(#notify_calls, 1, "missing RTK banner should only appear once per Neovim session")
end

local function test_rejected_git_command_is_safe_in_fast_event()
  local wait_for_fast_event = async.wrap(function(callback)
    local timer = assert(vim.uv.new_timer(), "failed to create timer")
    timer:start(0, 0, function()
      local ok, argv_or_err, maybe_err = pcall(runtime.split_safe_command, "git reset --hard")
      local observed = {
        ok = ok,
        argv = argv_or_err,
        err = maybe_err,
        fast_event = vim.in_fast_event(),
      }
      timer:stop()
      timer:close()
      vim.schedule(function()
        callback(observed)
      end)
    end)
  end, 1)

  local observed = wait_for_fast_event()
  assert_truthy(observed and observed.fast_event, "validator test should run inside a fast event")
  assert_truthy(observed.ok, "split_safe_command should not raise inside a fast event")
  assert_equal(observed.argv, nil, "rejected git command should still be rejected")
  assert_truthy(
    type(observed.err) == "string" and observed.err:match("Trusted repo shell only allows git"),
    "rejected git command should still explain the allowed git subcommands"
  )
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

      test_tool_sets_keep_shell_policy_explicit()
      test_readonly_shell_parser()
      test_readonly_shell_uses_async_system_wrapper()
      test_rtk_compacts_shell_output_when_available()
      test_rtk_missing_falls_back_to_plain_shell_output()
      test_rtk_missing_banner_only_notifies_once_per_session()
      test_rejected_git_command_is_safe_in_fast_event()
      require("CopilotChat.utils").schedule_main()
      test_edit_autosaves_relative_path()
      require("CopilotChat.utils").schedule_main()
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
