-- markdown-preview.nvim's <leader>cp only ever renders a single buffer --
-- clicking a relative link to a sibling file in that browser tab just
-- navigates the tab to http://localhost:<port>/<link>, which the plugin's
-- server has no route for. grip instead serves the whole repo tree, so
-- links between files resolve for real. One grip process per repo root is
-- kept running (tracked by root below) so the browser tab stays a live,
-- click-through view of the whole workspace instead of something to
-- reopen per file.
local grip = { jobs = {} }

local function repo_root()
  local dir = vim.fn.expand("%:p:h")
  local out = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
  -- A dotfiles repo rooted at $HOME would make grip serve the whole home
  -- directory, so treat it as "not in a repo" and serve just the file's dir.
  if vim.v.shell_error == 0 and out[1] and out[1] ~= vim.uv.os_homedir() then
    return out[1]
  end
  return dir
end

-- The wrapper imports grip, which lives in a Homebrew virtualenv, so it has to
-- run under that interpreter. <brew prefix>/opt/grip is the symlink Homebrew
-- keeps stable across upgrades, and the prefix differs per platform (macOS
-- arm64 /opt/homebrew, Linuxbrew /home/linuxbrew/.linuxbrew), so derive it from
-- wherever `grip` is on PATH instead of hardcoding one.
local function grip_python()
  local launcher = vim.fn.exepath("grip")
  if launcher == "" then
    return nil
  end
  local python = vim.fs.dirname(vim.fs.dirname(launcher)) .. "/opt/grip/libexec/bin/python"
  return vim.fn.executable(python) == 1 and python or nil
end

local function open_in_grip()
  local python = grip_python()
  if not python then
    vim.notify("grip not found; install it with `brew install grip`", vim.log.levels.ERROR)
    return
  end
  local root = repo_root()
  local relpath = vim.fn.expand("%:p"):sub(#root + 2)
  local entry = grip.jobs[root]

  if entry and entry.port then
    vim.ui.open(("http://localhost:%d/%s"):format(entry.port, relpath))
    return
  end

  if entry then
    -- Already starting (port not announced yet) -- avoid double-launching.
    return
  end

  entry = {}
  grip.jobs[root] = entry
  local wrapper = vim.fn.stdpath("config") .. "/scripts/grip-serve.py"
  -- A fixed port would collide with a still-running server left over from
  -- a previous Neovim session, so the wrapper picks its own free port and
  -- announces it here instead of us guessing one and a delay to match.
  -- No detach: the server only needs to outlive the buffer switches within
  -- this Neovim session, not Neovim itself. Detaching would leave it (and
  -- its port) running forever across restarts -- with a random free port
  -- picked every time, weeks of quitting and reopening Neovim would leak
  -- one orphaned process and blocked port per session.
  local stderr = {}
  vim.fn.jobstart({ python, wrapper, root }, {
    on_stderr = function(_, data)
      vim.list_extend(stderr, data)
    end,
    -- Forget the dead server so the next <leader>cp relaunches instead of
    -- reopening a port nothing listens on. Only a failure before the port
    -- was announced is worth reporting; later exits are Neovim quitting.
    on_exit = function(_, code)
      grip.jobs[root] = nil
      if code ~= 0 and not entry.port then
        vim.schedule(function()
          vim.notify("grip exited (" .. code .. "):\n" .. vim.trim(table.concat(stderr, "\n")), vim.log.levels.ERROR)
        end)
      end
    end,
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        local port = line:match("^PORT=(%d+)")
        if port then
          entry.port = tonumber(port)
          vim.notify(("grip serving %s on :%d"):format(root, entry.port), vim.log.levels.INFO)
          vim.schedule(function()
            vim.ui.open(("http://localhost:%d/%s"):format(entry.port, relpath))
          end)
        end
      end
    end,
  })
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown", "markdown.mdx" },
  callback = function(ev)
    -- LazyVim's own ft-scoped key handler sets its buffer-local <leader>cp
    -- (-> MarkdownPreviewToggle) on this same FileType event, and its
    -- autocmd is registered after this one, so it fires after and clobbers
    -- a plain keymap.set call here. Deferring to the next event-loop tick
    -- runs this after every synchronous FileType handler, ours last.
    vim.schedule(function()
      vim.keymap.set("n", "<leader>cp", open_in_grip, { buffer = ev.buf, desc = "Grip preview (repo workspace)" })
    end)
  end,
})

return {
  -- Use the Homebrew-provided Prettier formatter for explicit LazyFormat runs.
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        markdown = { "prettier" },
        ["markdown.mdx"] = { "prettier" },
      },
    },
  },

  -- rumdl: LSP-based Markdown linter (Mason: `rumdl`, lspconfig server `rumdl`).
  -- Replaces markdownlint-cli2 as the sole markdown linter -- running both
  -- produced duplicate/conflicting diagnostics on the same buffer. Formatting is
  -- untouched: conform.nvim/prettier above always wins over LSP-provided
  -- formatting, so rumdl's own formatter never engages as long as nothing calls
  -- vim.lsp.buf.format() directly for markdown buffers.
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        rumdl = {},
      },
    },
  },

  -- NOTE: LazyVim's own `lang.markdown` extra (extras/lang/markdown.lua) sets
  -- linters_by_ft.markdown = { "markdownlint-cli2" } as its baseline default.
  -- Removing our own prior override of that key is not enough by itself -- the
  -- extra's default reasserts itself -- so it must be explicitly emptied here to
  -- actually stop markdownlint-cli2 from firing alongside rumdl.
  {
    "mfussenegger/nvim-lint",
    opts = {
      linters_by_ft = {
        markdown = {},
      },
    },
  },
}
