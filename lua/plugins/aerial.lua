return {
  {
    "stevearc/aerial.nvim",
    opts = function(_, opts)
      opts = opts or {}
      opts.layout = vim.tbl_deep_extend("force", opts.layout or {}, {
        default_direction = "left",
      })
      -- After jumping to a symbol, show the target line 1 line below the
      -- top of the window. Plain "zt" isn't enough here because LazyVim's
      -- global 'scrolloff=4' forces at least 4 lines of context, pushing
      -- the target line further down. Rather than temporarily zeroing and
      -- restoring 'scrolloff' (which left it briefly inconsistent with the
      -- view and caused Neovim to force an extra scroll on the very next
      -- j/k), just set a permanent window-local scrolloff=1: this gives a
      -- stable 1-line margin on jump, and normal j/k afterwards keep
      -- respecting that same margin instead of "correcting" it later.
      opts.post_jump_cmd = "setlocal scrolloff=1 | normal! zt"
    end,
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "make" } },
  },
  {
    "nvim-lualine/lualine.nvim",
    optional = true,
    opts = function(_, opts)
      local function is_worktree_path()
        local filename = vim.api.nvim_buf_get_name(0)
        return filename ~= "" and filename:find("/%.worktrees/", 1) ~= nil
      end

      local worktree_component = {
        function()
          return "🌿 worktree"
        end,
        cond = is_worktree_path,
      }

      local filename_component = {
        "filename",
        path = 0,
        symbols = {
          modified = " ●",
          readonly = " 󰌾",
          unnamed = "[No Name]",
        },
      }

      local inactive_filename_component = vim.deepcopy(filename_component)
      inactive_filename_component.fmt = nil

      opts.options = opts.options or {}
      opts.options.disabled_filetypes = opts.options.disabled_filetypes or {}
      opts.options.disabled_filetypes.winbar = opts.options.disabled_filetypes.winbar or {}
      opts.winbar = opts.winbar or {}
      opts.winbar.lualine_c = opts.winbar.lualine_c or {}

      if #opts.winbar.lualine_c == 0 then
        table.insert(opts.winbar.lualine_c, worktree_component)
        table.insert(opts.winbar.lualine_c, filename_component)
      end

      if not opts.inactive_winbar or vim.tbl_isempty(opts.inactive_winbar) then
        opts.inactive_winbar = {
          lualine_c = { inactive_filename_component },
        }
      end
    end,
  },
}
