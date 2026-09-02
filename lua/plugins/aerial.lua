return {
  {
    "stevearc/aerial.nvim",
    -- Buffer-wide navigation of the symbol tree (works for YAML/Helm and any
    -- other language aerial supports), without needing the outline window
    -- open. Lowercase = move to next/prev symbol overall (siblings, when at
    -- the same nesting depth); uppercase = jump to the parent, moving
    -- forwards/backwards (mirrors the `]h`/`]H`, `]c`/`]C` case convention
    -- already used elsewhere in this config for "next" vs "outer/broader").
    keys = {
      { "]o", function() require("aerial").next() end, desc = "Next Symbol" },
      { "[o", function() require("aerial").prev() end, desc = "Prev Symbol" },
      { "]O", function() require("aerial").next_up() end, desc = "Up & Next Symbol (parent)" },
      { "[O", function() require("aerial").prev_up() end, desc = "Up & Prev Symbol (parent)" },
    },
    opts = function(_, opts)
      opts = opts or {}
      opts.layout = vim.tbl_deep_extend("force", opts.layout or {}, {
        default_direction = "left",
      })

      -- yaml-language-server (used directly, and by helm-ls under the hood)
      -- reports each item of a YAML sequence as a "Module" symbol whose name
      -- is just its numeric index (e.g. "0", "1", "2"), which makes the
      -- outline useless for lists of objects like a Helm `applications:`
      -- array. Relabel those using a meaningful key from the object itself
      -- (name/id/key first, falling back to the first scalar field found),
      -- pulled from the raw LSP symbol's `detail` (aerial doesn't keep it).
      local label_keys = { "name", "id", "key" }
      opts.post_parse_symbol = function(_, item, ctx)
        if ctx.backend_name == "lsp" and item.kind == "Module" and item.name:match("^%d+$") then
          local raw_children = ctx.symbol and ctx.symbol.children
          if raw_children then
            for _, key in ipairs(label_keys) do
              for _, child in ipairs(raw_children) do
                if child.name == key and child.detail and child.detail ~= "" then
                  item.name = child.detail
                  return true
                end
              end
            end
            for _, child in ipairs(raw_children) do
              if child.detail and child.detail ~= "" then
                item.name = ("%s: %s"):format(child.name, child.detail)
                return true
              end
            end
          end
        end
        return true
      end
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
