local M = {}

local uv = vim.uv or vim.loop
local active = {}

local function spinner_frame()
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.util and snacks.util.spinner then
    return snacks.util.spinner()
  end
  return "…"
end

local function render(id)
  local state = active[id]
  if not state then
    return
  end

  vim.notify(("%s %s"):format(spinner_frame(), state.message), state.level, {
    id = id,
    title = state.title,
    timeout = false,
    history = false,
  })
end

function M.start(id, title, message, level)
  M.stop(id)

  local timer = uv.new_timer()
  active[id] = {
    timer = timer,
    title = title,
    message = message,
    level = level or vim.log.levels.INFO,
  }

  render(id)
  timer:start(
    80,
    80,
    vim.schedule_wrap(function()
      render(id)
    end)
  )
end

function M.update(id, message, level)
  local state = active[id]
  if not state then
    return
  end

  state.message = message or state.message
  state.level = level or state.level
  render(id)
end

function M.stop(id, message, level, icon)
  local state = active[id]
  if state then
    if state.timer and not state.timer:is_closing() then
      state.timer:stop()
      state.timer:close()
    end
    active[id] = nil
  end

  if not message then
    return
  end

  local title = state and state.title or nil
  vim.notify((icon and icon .. " " or "") .. message, level or vim.log.levels.INFO, {
    id = id,
    title = title,
  })
end

return M
