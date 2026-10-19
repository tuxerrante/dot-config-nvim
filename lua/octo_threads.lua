-- Review thread navigation inside an Octo PR buffer.
--
-- The PR buffer is one long document: description, timeline, then every review
-- thread at the very end. Reaching the comments therefore means paging past the
-- description and a Copilot review first, and `]c` / `[c` (octo's own mappings)
-- stop at every comment on the way.
--
-- Octo marks each thread region with an extmark in `OCTO_THREAD_NS` and stores
-- that thread's metadata on the buffer object, keyed by mark id
-- (`ui/writers.lua:3795`), so the threads can be walked directly.

local M = {}

---@param bufnr integer|nil
local function octo_buffer(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local buf = _G.octo_buffers and _G.octo_buffers[bufnr]
  if not buf or not buf.threadsMetadata then
    return nil
  end
  return buf, bufnr
end

-- `threadsMetadata` knows where a thread is and what it points at, but not
-- whether it is resolved or outdated. That lives on the PR node the buffer was
-- rendered from, which is the same list `write_timeline_items` matched reviews
-- against.
local function details_by_thread_id(buf)
  local by_id = {}
  local node = buf.node or {}
  local threads = node.reviewThreads and node.reviewThreads.nodes or {}
  for _, thread in ipairs(threads) do
    by_id[thread.id] = thread
  end
  return by_id
end

local function text(value)
  if value == nil or value == vim.NIL then
    return nil
  end
  return value
end

---Every review thread in the buffer, in buffer order.
---@param bufnr integer|nil
function M.list(bufnr)
  local buf, nr = octo_buffer(bufnr)
  if not buf then
    return {}
  end

  local ns = require("octo.constants").OCTO_THREAD_NS
  local details = details_by_thread_id(buf)
  local threads = {}

  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(nr, ns, 0, -1, {})) do
    local meta = buf.threadsMetadata[tostring(mark[1])]
    if meta then
      local node = details[meta.threadId] or {}
      local comments = node.comments and node.comments.nodes or {}
      local first = comments[1] or {}
      table.insert(threads, {
        lnum = mark[2] + 1,
        path = text(meta.path) or "?",
        line = text(meta.line),
        resolved = node.isResolved == true,
        outdated = node.isOutdated == true,
        count = #comments,
        author = first.author and text(first.author.login) or nil,
        body = text(first.body),
      })
    end
  end

  table.sort(threads, function(a, b)
    return a.lnum < b.lnum
  end)
  return threads
end

function M.label(thread)
  local marker = thread.resolved and "✓" or "●"
  local where = thread.path .. (thread.line and (":" .. thread.line) or "")
  local parts = { marker .. " " .. where }
  if thread.outdated then
    table.insert(parts, "outdated")
  end
  if thread.count > 1 then
    table.insert(parts, thread.count .. " comments")
  end
  local summary = thread.body and vim.trim(vim.split(thread.body, "\n", { plain = true })[1] or "") or ""
  if thread.author then
    summary = thread.author .. (summary ~= "" and (": " .. summary) or "")
  end
  if summary ~= "" then
    table.insert(parts, summary)
  end
  return table.concat(parts, "  ")
end

local function jump_to(thread, index, total)
  vim.api.nvim_win_set_cursor(0, { thread.lnum, 0 })
  -- Resolved and outdated threads are rendered folded; open just this one.
  vim.cmd("normal! zv")
  -- The extmark starts at the diff snippet. The `THREAD: path:line` header is
  -- virtual text a couple of lines above it, so pull it into view.
  local view = vim.fn.winsaveview()
  view.topline = math.max(1, thread.lnum - 3)
  vim.fn.winrestview(view)

  local prefix = index and total and string.format("thread %d/%d  ", index, total) or ""
  vim.api.nvim_echo({ { prefix .. M.label(thread), "Comment" } }, false, {})
end

---Move to the next (`step > 0`) or previous review thread, wrapping around.
---@param step integer
function M.jump(step)
  local threads = M.list()
  if #threads == 0 then
    vim.notify("octo: no review threads in this buffer", vim.log.levels.INFO)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local index
  if step < 0 then
    for i = #threads, 1, -1 do
      if threads[i].lnum < cursor then
        index = i
        break
      end
    end
    index = index or #threads
  else
    for i = 1, #threads do
      if threads[i].lnum > cursor then
        index = i
        break
      end
    end
    index = index or 1
  end

  jump_to(threads[index], index, #threads)
end

---Jump from the thread under the cursor to the file and line it points at.
--
-- Octo ships `go_to_file` for this, but it reads the line straight out of the
-- thread metadata and hands it to `nvim_win_set_cursor`, which throws when the
-- file has since become shorter than an outdated thread's original line.
function M.goto_source()
  local buf = octo_buffer()
  local thread = buf and buf:get_thread_at_cursor()
  if not thread then
    vim.notify("octo: no review thread under the cursor", vim.log.levels.INFO)
    return
  end

  local path = text(thread.path)
  if not path then
    vim.notify("octo: this thread has no file attached", vim.log.levels.WARN)
    return
  end

  -- The path is repo-relative, and the cwd may be any directory inside the
  -- worktree, so fall back to the worktree root.
  local cwd = vim.fn.getcwd()
  local root = vim.fs.root(cwd, ".git")
  local target
  for _, candidate in ipairs({ vim.fs.joinpath(cwd, path), root and vim.fs.joinpath(root, path) }) do
    if candidate and vim.uv.fs_stat(candidate) then
      target = candidate
      break
    end
  end
  if not target then
    vim.notify("octo: " .. path .. " not found under " .. (root or cwd), vim.log.levels.WARN)
    return
  end

  -- Setting the ' mark also pushes the jumplist, so `<C-o>` comes back here.
  vim.cmd("normal! m'")
  vim.cmd.edit(vim.fn.fnameescape(target))

  local line = tonumber(text(thread.line)) or 1
  line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(0)))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.cmd("normal! zvzz")
end

---Pick a review thread from a list and jump to it.
function M.pick()
  local threads = M.list()
  if #threads == 0 then
    vim.notify("octo: no review threads in this buffer", vim.log.levels.INFO)
    return
  end

  vim.ui.select(threads, {
    prompt = "Review threads",
    format_item = M.label,
  }, function(choice)
    if choice then
      jump_to(choice)
    end
  end)
end

return M
