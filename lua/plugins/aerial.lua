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
    "SmiteshP/nvim-navic",
    optional = true,
    opts = function(_, opts)
      opts = opts or {}
      opts.separator = " › "
      opts.depth_limit = 3
      opts.depth_limit_indicator = "…"
      opts.highlight = false
      opts.safe_output = true
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    optional = true,
    opts = function(_, opts)
      local filename_component = {
        "filename",
        path = 0,
        fmt = function(str)
          return str == "" and str or (str .. "  ›")
        end,
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
        table.insert(opts.winbar.lualine_c, filename_component)
      end

      table.insert(opts.winbar.lualine_c, {
        "navic",
        color_correction = "dynamic",
        cond = function()
          local ok, navic = pcall(require, "nvim-navic")
          return ok and navic.is_available()
        end,
      })

      if not opts.inactive_winbar or vim.tbl_isempty(opts.inactive_winbar) then
        opts.inactive_winbar = {
          lualine_c = { inactive_filename_component },
        }
      end
    end,
  },
}
