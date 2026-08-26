-- Shared prompt helpers for one-shot CopilotChat actions.
local runtime = require("copilotchat_runtime")
local DEFAULT_TOOLS = runtime.DEFAULT_TOOLS
local DEFAULT_TRUSTED_TOOLS = runtime.DEFAULT_TRUSTED_TOOLS
local EDIT_TOOLS = runtime.EDIT_TOOLS
local EDIT_TRUSTED_TOOLS = runtime.EDIT_TRUSTED_TOOLS
local SHELL_TOOLS = runtime.SHELL_TOOLS
local SHELL_TRUSTED_TOOLS = runtime.SHELL_TRUSTED_TOOLS

local function prompt_and_ask(prompt, config)
  vim.ui.input({ prompt = prompt }, function(input)
    if input and input ~= "" then
      require("CopilotChat").ask(input, config)
    end
  end)
end

local function ask_with_selection()
  prompt_and_ask("Copilot Selection Task: ", {
    tools = DEFAULT_TOOLS,
    trusted_tools = DEFAULT_TRUSTED_TOOLS,
    resources = "selection",
    remember_as_sticky = false,
  })
end

-- Post-process responses through Caveman without bypassing user callbacks.
local function with_caveman(config)
  local caveman = require("caveman")
  local user_callback = config.callback

  config.callback = function(response, source)
    if user_callback then
      user_callback(response, source)
    end

    response.content = caveman.process(response.content or "")
  end

  return config
end

local function ask_with_caveman()
  local mode = vim.api.nvim_get_mode().mode
  local config = {
    tools = DEFAULT_TOOLS,
    trusted_tools = DEFAULT_TRUSTED_TOOLS,
    remember_as_sticky = false,
  }

  if mode:match("[vV\22]") then
    config.resources = "selection"
  end

  prompt_and_ask("Copilot Caveman Task: ", with_caveman(config))
end

local function ask_with_shell()
  prompt_and_ask("Copilot Shell Task: ", {
    tools = SHELL_TOOLS,
    trusted_tools = SHELL_TRUSTED_TOOLS,
    remember_as_sticky = false,
  })
end

local function ask_with_edit()
  prompt_and_ask("Copilot Edit Task: ", {
    tools = EDIT_TOOLS,
    trusted_tools = EDIT_TRUSTED_TOOLS,
    remember_as_sticky = false,
  })
end

-- Keep chat continuation helpers together: they reuse the active chat buffer
-- instead of opening a brand new request flow.
local function focus_chat_input(chat)
  chat.chat:focus()

  if chat.config and chat.config.auto_insert_mode then
    vim.cmd("startinsert")
  end
end

local function continue_chat_with_selection()
  local chat = require("CopilotChat")
  local constants = require("CopilotChat.constants")

  chat.open()
  local current = chat.chat:get_message(constants.ROLE.USER, true)
  local content = current and current.content or ""

  local function has_selection_marker(text)
    if not text then
      return false
    end

    return text:match("^%s*#selection") or text:match("\n%s*#selection")
  end

  if not has_selection_marker(content) then
    content = content == "" and "#selection\n\n" or "#selection\n\n" .. content
  end

  chat.chat:add_message({
    role = constants.ROLE.USER,
    content = content,
  }, true)
  focus_chat_input(chat)
end

local function handle_selection_request()
  local chat = require("CopilotChat")
  if chat.chat:visible() then
    continue_chat_with_selection()
  else
    ask_with_selection()
  end
end

local function restore_last_prompt()
  local chat = require("CopilotChat")
  local constants = require("CopilotChat.constants")

  chat.open()

  local current = chat.chat:visible() and chat.chat:get_message(constants.ROLE.USER, true) or nil
  local messages = chat.chat:get_messages()
  local last_prompt = nil

  for i = #messages, 1, -1 do
    local message = messages[i]
    if message.role == constants.ROLE.USER and message.content and vim.trim(message.content) ~= "" then
      if not current or message.id ~= current.id then
        last_prompt = message.content
        break
      end
    end
  end

  if not last_prompt and current and current.content and vim.trim(current.content) ~= "" then
    last_prompt = current.content
  end

  if not last_prompt then
    return
  end

  chat.chat:add_message({
    role = constants.ROLE.USER,
    content = last_prompt,
  }, true)
  focus_chat_input(chat)
end

-- Session helpers stay tiny so keymaps can reference named actions.
local function load_recent_session()
  require("copilotchat_history").load_recent_session()
end

local function save_session()
  require("copilotchat_history").save_session_as()
end

return {
  {
    "CopilotC-Nvim/CopilotChat.nvim",
    cmd = {
      "CopilotPrepReview",
    },
    init = function()
      -- Buffer-local UX tweaks for the dedicated Copilot chat window.
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "copilot-chat",
        callback = function(ev)
          vim.keymap.set("i", "<Tab>", function()
            require("CopilotChat.completion").complete()
          end, { buffer = ev.buf, desc = "CopilotChat Complete" })

          vim.keymap.set("i", "<C-s>", "<Nop>", {
            buffer = ev.buf,
            desc = "CopilotChat Disable Ctrl-S",
          })

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
      -- Global entrypoints for the chat UI and custom workflows.
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
        handle_selection_request,
        desc = "Send Selection to Copilot",
        mode = "v",
      },
      {
        "<leader>at",
        function()
          prompt_and_ask("Copilot Task: ", {
            tools = DEFAULT_TOOLS,
            trusted_tools = DEFAULT_TRUSTED_TOOLS,
            remember_as_sticky = false,
          })
        end,
        desc = "Copilot Task",
        mode = { "n", "x" },
      },
      {
        "<leader>ab",
        ask_with_shell,
        desc = "Copilot Task (Shell)",
        mode = { "n", "x" },
      },
      {
        "<leader>ae",
        ask_with_edit,
        desc = "Copilot Task (Edit)",
        mode = { "n", "x" },
      },
      {
        "<leader>av",
        ask_with_caveman,
        desc = "Copilot Task (Caveman)",
        mode = { "n", "x" },
      },
      {
        "<leader>aw",
        save_session,
        desc = "Save Copilot Session",
        mode = "n",
      },
      {
        "<leader>ay",
        restore_last_prompt,
        desc = "Replay Last Copilot Prompt",
        mode = "n",
      },
      {
        "<leader>al",
        load_recent_session,
        desc = "Load Recent Copilot Session",
        mode = "n",
      },
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
      -- Preserve the existing chat UX while layering local defaults.
      opts = opts or {}
      opts.tools = DEFAULT_TOOLS
      opts.system_prompt = vim.trim((opts.system_prompt or "") .. "\n\n" .. runtime.SYSTEM_PROMPT)
      opts.trusted_tools = DEFAULT_TRUSTED_TOOLS
      opts.remember_as_sticky = false
      opts.chat_autocomplete = false
      opts.auto_fold = true
      opts.mappings = vim.tbl_deep_extend("force", opts.mappings or {}, {
        submit_prompt = {
          insert = "<C-j>",
        },
      })
      return opts
    end,
    config = function(_, opts)
      -- Extra integrations are initialized after the base plugin setup.
      require("CopilotChat").setup(opts)
      runtime.patch_config()
      require("copilotchat_pretty").setup()
      require("copilotchat_history").setup()
      require("copilotchat_review_prep").setup()
    end,
  },
  {
    "saghen/blink.cmp",
    optional = true,
    opts = function(_, opts)
      -- Disable blink sources inside CopilotChat's prompt buffer.
      opts = opts or {}
      opts.sources = opts.sources or {}
      opts.sources.per_filetype = opts.sources.per_filetype or {}
      opts.sources.per_filetype["copilot-chat"] = {}
    end,
  },
}
