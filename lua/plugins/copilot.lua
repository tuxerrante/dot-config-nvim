local function reduce_with_rtk(text)
  if not text or text == "" or vim.fn.executable("rtk") == 0 then
    return text
  end

  local output = vim.fn.system({ "rtk" }, text)
  if vim.v.shell_error ~= 0 or not output or output == "" then
    return text
  end
  return output
end

local function ask_with_selection()
  vim.ui.input({ prompt = "Copilot Selection Task: " }, function(input)
    if input and input ~= "" then
      require("CopilotChat").ask(reduce_with_rtk(input), {
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

  if chat.config and chat.config.auto_insert_mode then
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

-- Banner: show model, session size, tokens and duration as virtual text
local banner_ns = vim.api.nvim_create_namespace("copilot_chat_banner")

local function safe_require(name)
  local ok, mod = pcall(require, name)
  if ok then
    return mod
  end
  return nil
end

local function get_banner_text()
  local chat = safe_require("CopilotChat")
  if not chat then
    return "Model: - | Session: - | Tokens: - | Time: -"
  end

  local model = "-"
  pcall(function()
    if chat.config and chat.config.model then
      model = tostring(chat.config.model)
    end
  end)

  local session_size = "-"
  pcall(function()
    if chat.chat then
      if type(chat.chat.messages) == "table" then
        session_size = tostring(#chat.chat.messages)
      else
        -- try common method names defensively
        if type(chat.chat.get_history) == "function" then
          local hist = chat.chat:get_history()
          if type(hist) == "table" then
            session_size = tostring(#hist)
          end
        end
      end
    end
  end)

  local tokens = "-"
  local duration = "-"
  pcall(function()
    -- best-effort: some implementations expose session info
    if chat.session and type(chat.session) == "table" then
      if chat.session.tokens then
        tokens = tostring(chat.session.tokens)
      end
      if chat.session.started_at and chat.session.ended_at then
        duration = tostring(math.floor((chat.session.ended_at - chat.session.started_at))) .. "s"
      elseif chat.session.started_at then
        duration = tostring(math.floor(vim.loop.hrtime() / 1e9 - chat.session.started_at)) .. "s"
      end
    end
  end)

  return string.format("Model: %s | Session: %s msgs | Tokens: %s | Time: %s", model, session_size, tokens, duration)
end

local function update_banner(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ok, ft = pcall(vim.api.nvim_buf_get_option, bufnr, "filetype")
  if not ok or ft ~= "copilot-chat" then
    return
  end

  -- clear
  vim.api.nvim_buf_clear_namespace(bufnr, banner_ns, 0, -1)

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 then
    return
  end
  local lnum = math.max(0, line_count - 1)
  local text = get_banner_text()

  vim.api.nvim_buf_set_extmark(bufnr, banner_ns, lnum, 0, {
    virt_text = { { " " .. text, "Comment" } },
    virt_text_pos = "eol",
  })
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
        end,
      })
    end,
    keys = {
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
      {
        "<leader>aa",
        function()
          vim.ui.input({ prompt = "Advisor note (optional): " }, function(input)
            local chat = require("CopilotChat")
            local constants = require("CopilotChat.constants")
            local message = chat.chat:get_message(constants.ROLE.USER, true)
            local conversation = message and message.content or ""
            local note = input or "Advisor check requested"
            chat.ask("[Advisor check] " .. note .. "\n\nConversation snapshot:\n" .. conversation, {
              model = "claude-opus-5",
              tools = "copilot",
              remember_as_sticky = false,
            })
          end)
        end,
        desc = "Request advisor check (CopilotChat)",
        mode = "n",
      },
    },
    opts = function(_, opts)
      opts = opts or {}
      opts.model = "gpt-5-mini"
      opts.advisor_model = "claude-opus-5"
      opts.advisor_enabled = true
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
      opts = opts or {}
      opts.sources = opts.sources or {}
      opts.sources.per_filetype = opts.sources.per_filetype or {}
      opts.sources.per_filetype["copilot-chat"] = {}
    end,
  },
}
