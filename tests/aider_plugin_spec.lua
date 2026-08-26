local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      (message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual)
    )
  end
end

local function aider_spec()
  package.loaded["plugins.aider"] = nil
  return require("plugins.aider")[1]
end

local function test_aider_uses_rich_home_defaults()
  local spec = aider_spec()
  local original_jobstart = vim.fn.jobstart
  local captured

  spec.init()
  vim.fn.jobstart = function(argv, opts)
    captured = { argv = argv, opts = opts }
    return 1
  end

  local ok, err = pcall(vim.cmd, "Aider")
  vim.fn.jobstart = original_jobstart
  pcall(vim.api.nvim_del_user_command, "Aider")
  pcall(vim.api.nvim_del_user_command, "LiteLLM")

  assert(ok, err)
  assert_equal(captured.argv, { vim.fn.expand("~/.local/bin/aider-aoai") }, "launcher should not disable Aider UX")
  assert_equal(captured.opts.cwd, vim.fs.root(vim.fn.getcwd(), ".git"), "Aider should start at the repository root")
  assert_equal(captured.opts.term, true, "Aider should run in a terminal job")
end

function M.run()
  test_aider_uses_rich_home_defaults()
  print("PASS aider_plugin_spec")
end

return M
