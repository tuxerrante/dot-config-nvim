local M = {}

local uv = vim.uv or vim.loop

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "CopilotChat" })
end

local function get_history_path(history_path)
  local path = history_path
  if not path then
    local chat = require("CopilotChat")
    path = chat.config and chat.config.history_path or nil
  end

  if not path or path == "" then
    return nil
  end

  return vim.fs.normalize(path)
end

local function session_name_from_prompt()
  local chat = require("CopilotChat")
  local constants = require("CopilotChat.constants")
  local messages = chat.chat and chat.chat:get_messages() or {}

  for _, message in ipairs(messages) do
    if message.role == constants.ROLE.USER and message.content and vim.trim(message.content) ~= "" then
      local first_line = vim.split(vim.trim(message.content), "\n", { plain = true })[1] or ""
      first_line = first_line:gsub("^#selection%s*", "")
      first_line = first_line:gsub("[^%w%s%-_]", "")
      first_line = vim.trim(first_line):gsub("%s+", "-"):lower()
      if first_line ~= "" then
        return os.date("%Y%m%d-%H%M-") .. first_line:sub(1, 36)
      end
      break
    end
  end

  return os.date("%Y%m%d-%H%M")
end

local function sanitize_session_name(name)
  local cleaned = vim.trim(name)
  cleaned = cleaned:gsub('[/\\:%*%?"<>|]', "-")
  cleaned = cleaned:gsub("%s+", "-")
  cleaned = cleaned:gsub("%-+", "-")
  cleaned = cleaned:gsub("^%-+", ""):gsub("%-+$", "")
  return cleaned
end

local function format_timestamp(seconds)
  if not seconds or seconds <= 0 then
    return "unknown time"
  end

  local now = os.time()
  local delta = math.max(0, now - seconds)
  if delta < 60 then
    return "just now"
  end
  if delta < 3600 then
    return string.format("%dm ago", math.floor(delta / 60))
  end
  if delta < 86400 then
    return string.format("%dh ago", math.floor(delta / 3600))
  end
  if delta < 604800 then
    return string.format("%dd ago", math.floor(delta / 86400))
  end

  return os.date("%Y-%m-%d %H:%M", seconds)
end

function M.list_recent_sessions(history_path)
  local path = get_history_path(history_path)
  if not path then
    return {}
  end

  local sessions = {}
  local iter = vim.fs.dir(path)
  if not iter then
    return sessions
  end

  for name, entry_type in iter do
    if entry_type == "file" and name:sub(-5) == ".json" then
      local full_path = path .. "/" .. name
      local stat = uv.fs_stat(full_path)
      local mtime = stat and stat.mtime and (stat.mtime.sec or stat.mtime) or 0
      table.insert(sessions, {
        name = name:gsub("%.json$", ""),
        path = full_path,
        mtime = mtime,
        size = stat and stat.size or 0,
      })
    end
  end

  table.sort(sessions, function(a, b)
    if a.mtime == b.mtime then
      return a.name < b.name
    end
    return a.mtime > b.mtime
  end)

  return sessions
end

function M.save_session_as()
  local chat = require("CopilotChat")

  vim.ui.input({
    prompt = "Save Copilot session as: ",
    default = session_name_from_prompt(),
  }, function(input)
    if input == nil then
      return
    end

    local name = sanitize_session_name(input)
    if name == "" then
      notify("Session name cannot be empty", vim.log.levels.WARN)
      return
    end

    chat.save(name)
  end)
end

function M.load_recent_session()
  local history_path = get_history_path()
  if not history_path then
    notify("CopilotChat history_path is not configured", vim.log.levels.WARN)
    return
  end

  local sessions = M.list_recent_sessions(history_path)
  if #sessions == 0 then
    notify("No saved Copilot sessions found. Save one with <leader>aw.", vim.log.levels.INFO)
    return
  end

  vim.ui.select(sessions, {
    prompt = "Load Copilot session> ",
    format_item = function(item)
      return string.format("%s  [%s]", item.name, format_timestamp(item.mtime))
    end,
  }, function(choice)
    if choice then
      require("CopilotChat").load(choice.name, history_path)
    end
  end)
end

function M.setup()
  if M._commands_registered then
    return
  end

  vim.api.nvim_create_user_command("CopilotChatLoadRecent", function()
    M.load_recent_session()
  end, { desc = "Load a recent CopilotChat session" })

  vim.api.nvim_create_user_command("CopilotChatSaveNamed", function()
    M.save_session_as()
  end, { desc = "Save the current CopilotChat session" })

  M._commands_registered = true
end

return M
