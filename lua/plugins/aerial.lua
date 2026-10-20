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

      -- LazyVim's default kind filter keeps Property/Field but drops
      -- Constant/Variable. In TypeScript that hides every `const x = ...`
      -- declaration and promotes the keys of its object literal to the top
      -- level, so the tree becomes a flat list of `name`, `version`, `files`.
      -- Show declarations instead, and drop the keys.
      local ts_kinds = {
        "Class",
        "Constant",
        "Constructor",
        "Enum",
        "Function",
        "Interface",
        "Method",
        "Module",
        "Namespace",
        "Struct",
        "Variable",
      }
      opts.filter_kind = opts.filter_kind or {}
      if type(opts.filter_kind) == "table" then
        for _, ft in ipairs({ "typescript", "typescriptreact", "javascript", "javascriptreact" }) do
          opts.filter_kind[ft] = ts_kinds
        end
      end

      -- tsserver emits every anonymous function argument as a symbol named
      -- `<function>` or `filter() callback`. They carry no information, so
      -- remove them and hoist any named symbols they contain into the
      -- enclosing scope. aerial reads `level`/`parent` as stored, so both are
      -- rebuilt here.
      local ts_clients = { vtsls = true, ts_ls = true, tsserver = true }
      local function is_callback(item)
        return item.kind == "Function" and (item.name == "<function>" or item.name:match("%) callback$") ~= nil)
      end
      local function hoist_callbacks(items, parent, level)
        local out = {}
        for _, item in ipairs(items) do
          if is_callback(item) then
            vim.list_extend(out, hoist_callbacks(item.children or {}, parent, level))
          else
            item.parent = parent
            item.level = level
            if item.children then
              item.children = hoist_callbacks(item.children, item, level + 1)
              if #item.children == 0 then
                item.children = nil
              end
            end
            table.insert(out, item)
          end
        end
        return out
      end
      opts.post_add_all_symbols = function(_, items, ctx)
        if ctx.backend_name == "lsp" and ts_clients[ctx.lang] then
          return hoist_callbacks(items, nil, 0)
        end
        return items
      end

      -- yaml-language-server (used directly, and by helm-ls under the hood)
      -- reports each item of a YAML sequence as a "Module" symbol whose name
      -- is just its numeric index (e.g. "0", "1", "2"), which makes the
      -- outline useless for lists of objects like a Helm `applications:`
      -- array. Relabel those using a meaningful key from the object itself
      -- (name/id/key first, falling back to the first scalar field found),
      -- pulled from the raw LSP symbol's `detail` (aerial doesn't keep it).
      local label_keys = { "name", "id", "key" }
      opts.post_parse_symbol = function(_, item, ctx)
        -- Locals inside function bodies are noise in the outline; only
        -- module-level constants/variables are worth listing.
        if
          ctx.backend_name == "lsp"
          and (item.kind == "Constant" or item.kind == "Variable")
          and item.level > 0
          and vim.tbl_contains({ "vtsls", "ts_ls", "tsserver" }, ctx.lang)
        then
          return false
        end
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
      -- Shows which worktree this is *and* where it points: branch, upstream,
      -- and how far the two have drifted. See lua/worktree.lua for the
      -- caching, since this runs on every winbar redraw.
      local worktree_component = {
        function()
          return require("worktree").badge()
        end,
        cond = function()
          return require("worktree").is_worktree()
        end,
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
