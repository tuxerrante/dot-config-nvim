return {
  {
    "stevearc/aerial.nvim",
    opts = function(_, opts)
      opts = opts or {}
      opts.layout = vim.tbl_deep_extend("force", opts.layout or {}, {
        default_direction = "left",
      })
    end,
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
