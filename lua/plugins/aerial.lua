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
      opts.winbar = opts.winbar or {}
      opts.winbar.lualine_c = opts.winbar.lualine_c or {}

      if #opts.winbar.lualine_c == 0 then
        table.insert(opts.winbar.lualine_c, {
          "filename",
          path = 1,
          symbols = {
            modified = " ●",
            readonly = " 󰌾",
            unnamed = "[No Name]",
          },
        })
      end

      table.insert(opts.winbar.lualine_c, {
        "navic",
        color_correction = "dynamic",
        cond = function()
          local ok, navic = pcall(require, "nvim-navic")
          return ok and navic.is_available()
        end,
      })
    end,
  },
}
