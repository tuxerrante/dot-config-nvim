local M = {}
local unpack_args = table.unpack or unpack

local function json_decode(text)
  return vim.json.decode(text, {
    luanil = {
      object = true,
      array = true,
    },
  })
end

local function render_json(value, depth)
  local value_type = type(value)
  local indent = string.rep("  ", depth)
  local next_indent = string.rep("  ", depth + 1)

  if value_type == "nil" then
    return "null"
  end

  if value_type == "boolean" or value_type == "number" then
    return tostring(value)
  end

  if value_type == "string" then
    if value:find("\n", 1, true) then
      local chomp = value:sub(-1) == "\n" and "|" or "|-"
      local lines = vim.split(value, "\n", { plain = true, trimempty = false })
      local content_indent = string.rep("  ", depth + 1)
      for i, line in ipairs(lines) do
        lines[i] = content_indent .. line
      end
      return chomp .. "\n" .. table.concat(lines, "\n")
    end

    return vim.json.encode(value)
  end

  if value_type ~= "table" then
    error("non-json value")
  end

  if vim.tbl_isempty(value) then
    return vim.islist(value) and "[]" or "{}"
  end

  if vim.islist(value) then
    local items = {}
    for _, item in ipairs(value) do
      table.insert(items, next_indent .. render_json(item, depth + 1))
    end

    return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "]"
  end

  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then
      error("non-string key")
    end
    table.insert(keys, key)
  end
  table.sort(keys)

  local items = {}
  for _, key in ipairs(keys) do
    table.insert(
      items,
      string.format("%s%s: %s", next_indent, vim.json.encode(key), render_json(value[key], depth + 1))
    )
  end

  return "{\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "}"
end

function M.pretty_json_value(value)
  local ok, rendered = pcall(render_json, value, 0)
  if ok then
    return rendered
  end
end

function M.pretty_json_string(text)
  if type(text) ~= "string" then
    return nil
  end

  local trimmed = vim.trim(text)
  if trimmed == "" then
    return nil
  end

  local first = trimmed:sub(1, 1)
  local last = trimmed:sub(-1)
  if not ((first == "{" and last == "}") or (first == "[" and last == "]")) then
    return nil
  end

  local ok, decoded = pcall(json_decode, trimmed)
  if not ok then
    return nil
  end

  return M.pretty_json_value(decoded)
end

local function truncate(text, max_len)
  if type(text) ~= "string" or #text <= max_len then
    return text
  end

  return text:sub(1, max_len - 3) .. "..."
end

local function truncate_middle(text, max_len)
  if type(text) ~= "string" or #text <= max_len then
    return text
  end

  local keep_left = math.floor((max_len - 3) / 2)
  local keep_right = max_len - 3 - keep_left
  return text:sub(1, keep_left) .. "..." .. text:sub(-keep_right)
end

local function compact_path(path)
  if type(path) ~= "string" then
    return path
  end

  local home = vim.uv.os_homedir()
  if home and path:find(home, 1, true) == 1 then
    path = "~" .. path:sub(#home + 1)
  end

  return truncate_middle(path, 96)
end

local function summarize_decoded_value(value)
  if type(value) ~= "table" then
    return nil
  end

  if type(value.command) == "string" then
    return "command: " .. truncate(value.command:gsub("%s+", " "), 96)
  end

  if type(value.path) == "string" then
    return "path: " .. compact_path(value.path)
  end

  if type(value.pattern) == "string" then
    return "pattern: " .. value.pattern
  end

  if type(value.target) == "string" then
    return "target: " .. value.target
  end

  if type(value.filename) == "string" then
    return "file: " .. compact_path(value.filename)
  end

  if type(value.url) == "string" then
    return "url: " .. truncate_middle(value.url, 96)
  end

  if type(value.scope) == "string" then
    return "scope: " .. value.scope
  end

  return nil
end

M.summarize_tool_arguments = summarize_decoded_value

function M.patch_prompts()
  local prompts = require("CopilotChat.prompts")
  if prompts._pretty_json_patched then
    return
  end

  local original_format_tool_output = prompts.format_tool_output
  prompts.format_tool_output = function(ok, output)
    local result = original_format_tool_output(ok, output)
    return M.pretty_json_string(result) or result
  end
  prompts._pretty_json_patched = true
end

function M.patch_chat_render()
  local chat = require("CopilotChat.ui.chat")
  if chat._pretty_json_patched then
    return
  end

  local utils = require("CopilotChat.utils")
  local original_render = chat.render

  chat.render = function(self, ...)
    local args = { ... }
    local original_inspect = vim.inspect
    local original_json_decode = utils.json_decode

    utils.json_decode = function(body)
      local ok, decoded = pcall(json_decode, body)
      if ok then
        local summary = summarize_decoded_value(decoded)
        if summary then
          return {
            __copilotchat_pretty_json = summary,
          }
        end

        local pretty = M.pretty_json_value(decoded)
        if pretty then
          return {
            __copilotchat_pretty_json = pretty,
          }
        end
      end

      local pretty = M.pretty_json_string(body)
      if pretty then
        return {
          __copilotchat_pretty_json = pretty,
        }
      end

      return original_json_decode(body)
    end

    vim.inspect = function(value, opts)
      if type(value) == "table" and rawget(value, "__copilotchat_pretty_json") then
        return value.__copilotchat_pretty_json
      end

      return original_inspect(value, opts)
    end

    local ok, result = xpcall(function()
      return original_render(self, unpack_args(args))
    end, debug.traceback)

    vim.inspect = original_inspect
    utils.json_decode = original_json_decode

    if not ok then
      error(result)
    end

    return result
  end

  chat._pretty_json_patched = true
end

function M.setup()
  M.patch_prompts()
  M.patch_chat_render()
end

return M
