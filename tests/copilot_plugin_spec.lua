local M = {}

local function assert_truthy(value, message)
  if not value then
    error(message or "expected truthy value")
  end
end

local function copilotchat_spec()
  package.loaded["plugins.copilot"] = nil

  for _, spec in ipairs(require("plugins.copilot")) do
    if spec[1] == "CopilotC-Nvim/CopilotChat.nvim" then
      return spec
    end
  end

  error("CopilotChat plugin spec not found")
end

local function test_copilot_prep_review_is_lazy_command_trigger()
  local spec = copilotchat_spec()

  assert_truthy(type(spec.cmd) == "table", "CopilotChat spec should declare lazy command triggers")
  assert_truthy(
    vim.tbl_contains(spec.cmd, "CopilotPrepReview"),
    "CopilotPrepReview should lazy-load CopilotChat from a cold start"
  )
end

function M.run()
  test_copilot_prep_review_is_lazy_command_trigger()
  print("PASS copilot_plugin_spec")
end

return M
