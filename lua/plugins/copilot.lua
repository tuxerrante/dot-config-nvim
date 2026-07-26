local function ask_with_selection()
  vim.ui.input({ prompt = "Copilot Selection Task: " }, function(input)
    if input and input ~= "" then
      require("CopilotChat").ask(input, {
        tools = "copilot",
        resources = "selection",
        remember_as_sticky = false,
      })
    end
  end)
end

local function continue_chat_with_selection()
  local chat = require("CopilotChat")
  local constants = require("CopilotChat.constants")

  chat.open()

  local current = chat.chat:get_message(constants.ROLE.USER, true)
  local content = current and current.content or ""

  if not content:match("(^|\n)%s*#selection") then
    content = content == "" and "#selection\n\n" or "#selection\n\n" .. content
  end

  chat.chat:add_message({
    role = constants.ROLE.USER,
    content = content,
  }, true)

  chat.chat:focus()
  if chat.config.auto_insert_mode then
    vim.cmd("startinsert")
  end
end

local function handle_selection_request()
  local chat = require("CopilotChat")
  if chat.chat:visible() then
    continue_chat_with_selection()
  else
    ask_with_selection()
  end
end

return {
  {
    "CopilotC-Nvim/CopilotChat.nvim",
    init = function()
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "copilot-chat",
        callback = function(ev)
          vim.keymap.set("i", "<Tab>", function()
            require("CopilotChat.completion").complete()
          end, { buffer = ev.buf, desc = "CopilotChat Complete" })

          vim.keymap.set("i", "<C-j>", function()
            local chat = require("CopilotChat")
            local constants = require("CopilotChat.constants")
            local message = chat.chat:get_message(constants.ROLE.USER, true)
            if message and message.content and message.content ~= "" then
              chat.ask(message.content)
            end
          end, { buffer = ev.buf, desc = "CopilotChat Submit" })
        end,
      })
    end,
    keys = {
      -- Remap to match previous Claude Code shortcuts
      {
        "<leader>ac",
        function()
          return require("CopilotChat").toggle()
        end,
        desc = "Toggle Copilot Chat",
        mode = { "n", "x" },
      },
      {
        "<leader>as",
        function()
          handle_selection_request()
        end,
        desc = "Send Selection to Copilot",
        mode = "v",
      },
      {
        "<leader>at",
        function()
          vim.ui.input({ prompt = "Copilot Task: " }, function(input)
            if input and input ~= "" then
              require("CopilotChat").ask(input, {
                tools = "copilot",
                remember_as_sticky = false,
              })
            end
          end)
        end,
        desc = "Copilot Task",
        mode = { "n", "x" },
      },
      -- Keep the defaults that don't conflict
      {
        "<leader>ax",
        function()
          return require("CopilotChat").reset()
        end,
        desc = "Clear (CopilotChat)",
        mode = { "n", "x" },
      },
      {
        "<leader>ap",
        function()
          require("CopilotChat").select_prompt()
        end,
        desc = "Prompt Actions (CopilotChat)",
        mode = { "n", "x" },
      },
    },
    opts = function(_, opts)
      opts = opts or {}
      opts.model = "claude-opus-5"
      opts.trusted_tools = { "file", "glob", "grep", "edit" }
      opts.chat_autocomplete = false
      opts.mappings = vim.tbl_deep_extend("force", opts.mappings or {}, {
        submit_prompt = {
          insert = "<C-j>",
        },
      })
      return opts
    end,
  },
  {
    "saghen/blink.cmp",
    optional = true,
    opts = function(_, opts)
      opts.sources = opts.sources or {}
      opts.sources.per_filetype = opts.sources.per_filetype or {}
      opts.sources.per_filetype["copilot-chat"] = {}
    end,
  },
}
