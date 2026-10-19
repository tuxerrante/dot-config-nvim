-- Worktree awareness: the winbar badge and a picker over `git worktree list`.
--
-- The badge is asked for on every winbar redraw, so every git call is cached
-- per worktree root and only recomputed when something plausibly changed:
-- focus/cwd switches, or a terminal job (lazygit) exiting.

local M = {}

local ICON = "🌿"

-- worktree root -> info table
local info_cache = {}
-- buffer directory -> worktree root, or `false` when the dir is not in a repo
local root_cache = {}
local did_setup = false

local function git(cwd, args)
  local cmd = vim.list_extend({ "git", "-C", cwd }, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait()
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  local out = vim.trim(res.stdout or "")
  return out ~= "" and out or nil
end

-- `.worktrees/pr-1402-kyverno-3.x` and `.worktrees/pr-1402` both mean PR 1402.
local function pr_number(root)
  return tonumber(root:match("/%.worktrees/pr%-(%d+)"))
end

local function collect(dir)
  local root = git(dir, { "rev-parse", "--show-toplevel" })
  if not root then
    return nil
  end
  root = vim.fs.normalize(root)

  local info = {
    root = root,
    name = vim.fs.basename(root),
    is_worktree = root:find("/%.worktrees/") ~= nil,
    pr = pr_number(root),
  }

  local branch = git(dir, { "branch", "--show-current" })
  if branch then
    info.branch = branch
    info.upstream = git(dir, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" })
    if info.upstream then
      local counts = git(dir, { "rev-list", "--left-right", "--count", "@{upstream}...HEAD" })
      local behind, ahead = (counts or ""):match("^(%d+)%s+(%d+)$")
      info.behind = tonumber(behind) or 0
      info.ahead = tonumber(ahead) or 0
    end
  else
    info.detached = true
    info.sha = git(dir, { "rev-parse", "--short", "HEAD" })
  end

  return info
end

-- The branch/upstream half of the badge, without the leading icon, so the
-- picker can reuse the exact same wording as the winbar.
function M.describe(info)
  if info.detached then
    local sha = info.sha or "?"
    return info.pr and ("PR #%d detached @%s"):format(info.pr, sha) or ("detached @%s"):format(sha)
  end

  local parts = { info.branch or "?" }

  if not info.upstream then
    table.insert(parts, "⚠ no upstream")
  else
    local remote, remote_branch = info.upstream:match("^([^/]+)/(.+)$")
    -- Collapse `origin/same-name` down to `origin`; the case worth spelling
    -- out in full is a local branch whose name has drifted from its remote.
    table.insert(parts, "→ " .. (remote_branch == info.branch and remote or info.upstream))

    local drift = ""
    if (info.ahead or 0) > 0 then
      drift = drift .. "↑" .. info.ahead
    end
    if (info.behind or 0) > 0 then
      drift = drift .. "↓" .. info.behind
    end
    if drift ~= "" then
      table.insert(parts, drift)
    end
  end

  if info.pr then
    table.insert(parts, "#" .. info.pr)
  end

  return table.concat(parts, " ")
end

local function buffer_dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then
    return vim.fn.getcwd()
  end
  return vim.fs.dirname(name)
end

--- Cached worktree info for the current buffer, or nil outside a repo.
function M.current()
  M.setup()

  local dir = buffer_dir()
  local root = root_cache[dir]

  if root == nil then
    local info = collect(dir)
    root_cache[dir] = info and info.root or false
    if info then
      info_cache[info.root] = info
    end
    return info
  end

  return root ~= false and info_cache[root] or nil
end

function M.is_worktree()
  local info = M.current()
  return info ~= nil and info.is_worktree
end

function M.badge()
  local info = M.current()
  return info and (ICON .. " " .. M.describe(info)) or ""
end

function M.refresh()
  info_cache = {}
  root_cache = {}
  vim.schedule(function()
    vim.cmd.redrawstatus({ bang = true })
  end)
end

--- Pick a worktree of the current repo and switch this session into it.
function M.pick()
  M.setup()

  local cwd = vim.fn.getcwd()
  local out = git(cwd, { "worktree", "list", "--porcelain" })
  if not out then
    vim.notify("worktree: not inside a git repository", vim.log.levels.WARN)
    return
  end

  local current = M.current()
  local current_root = current and current.root or vim.fs.normalize(cwd)

  local entries = {}
  local width = 0
  for _, block in ipairs(vim.split(out, "\n\n", { plain = true, trimempty = true })) do
    local path = block:match("worktree ([^\n]+)")
    if path then
      path = vim.fs.normalize(path)
      local entry = collect(path) or { root = path, name = vim.fs.basename(path), missing = true, pr = pr_number(path) }
      entry.prunable = block:match("\nprunable") ~= nil
      table.insert(entries, entry)
      width = math.max(width, #entry.name)
    end
  end

  if #entries < 2 then
    vim.notify("worktree: this repo has a single worktree", vim.log.levels.INFO)
    return
  end

  vim.ui.select(entries, {
    prompt = "Git worktrees",
    format_item = function(entry)
      local marker = entry.root == current_root and "●" or " "
      local detail
      if entry.missing then
        detail = entry.prunable and "⚠ missing on disk (prunable)" or "⚠ missing on disk"
      else
        detail = M.describe(entry)
      end
      return ("%s %-" .. width .. "s  %s"):format(marker, entry.name, detail)
    end,
  }, function(entry)
    if not entry or entry.root == current_root then
      return
    end
    if entry.missing then
      vim.notify(("worktree: %s no longer exists on disk"):format(entry.root), vim.log.levels.ERROR)
      return
    end

    require("review_switch").execute(current_root, entry.root, function(result, err)
      if err then
        vim.notify("worktree: " .. err, vim.log.levels.WARN)
        return
      end
      M.refresh()
      local summary = ("worktree: switched to %s (%s)"):format(entry.name, M.describe(entry))
      if result and #result.skipped_paths > 0 then
        summary = summary .. ("\n%d buffer(s) had no counterpart here"):format(#result.skipped_paths)
      end
      vim.notify(summary, vim.log.levels.INFO)
    end)
  end)
end

function M.setup()
  if did_setup then
    return
  end
  did_setup = true

  local group = vim.api.nvim_create_augroup("worktree_status", { clear = true })
  vim.api.nvim_create_autocmd({ "FocusGained", "DirChanged", "TermClose" }, {
    group = group,
    desc = "Re-read worktree state after anything that may have moved HEAD",
    callback = function()
      M.refresh()
    end,
  })

  vim.api.nvim_create_user_command("WorktreeRefresh", function()
    M.refresh()
  end, { desc = "Re-read git worktree state for the winbar badge" })

  vim.api.nvim_create_user_command("WorktreePick", function()
    M.pick()
  end, { desc = "Switch this session to another git worktree" })
end

return M
