local ts_filetypes = {
  "javascript",
  "javascriptreact",
  "javascript.jsx",
  "typescript",
  "typescriptreact",
  "typescript.tsx",
}

local eslint_roots = {
  "eslint.config.js",
  "eslint.config.cjs",
  "eslint.config.mjs",
  "eslint.config.ts",
  "eslint.config.cts",
  "eslint.config.mts",
  ".eslintrc",
  ".eslintrc.js",
  ".eslintrc.cjs",
  ".eslintrc.json",
  ".eslintrc.yaml",
  ".eslintrc.yml",
}

local biome_roots = {
  "biome.json",
  "biome.jsonc",
}

local function extend_unique(list, values)
  list = list or {}
  for _, value in ipairs(values) do
    if not vim.tbl_contains(list, value) then
      table.insert(list, value)
    end
  end
  return list
end

local function has_root_file(ctx, names)
  return #vim.fs.find(names, { path = ctx.dirname, upward = true }) > 0
end

local function has_binary(ctx, binary)
  if vim.fn.executable(binary) == 1 then
    return true
  end

  return #vim.fs.find("node_modules/.bin/" .. binary, { path = ctx.dirname, upward = true, type = "file" }) > 0
end

local function linter_condition(root_files, binary)
  return function(ctx)
    return has_root_file(ctx, root_files) and has_binary(ctx, binary)
  end
end

return {
  {
    "mfussenegger/nvim-lint",
    opts = function(_, opts)
      opts.linters = opts.linters or {}
      opts.linters_by_ft = opts.linters_by_ft or {}

      opts.linters.biomejs = vim.tbl_deep_extend("force", opts.linters.biomejs or {}, {
        condition = linter_condition(biome_roots, "biome"),
      })

      opts.linters.eslint_d = vim.tbl_deep_extend("force", opts.linters.eslint_d or {}, {
        condition = linter_condition(eslint_roots, "eslint_d"),
      })

      opts.linters.eslint = vim.tbl_deep_extend("force", opts.linters.eslint or {}, {
        condition = linter_condition(eslint_roots, "eslint"),
      })

      for _, ft in ipairs(ts_filetypes) do
        opts.linters_by_ft[ft] = extend_unique(opts.linters_by_ft[ft], { "biomejs", "eslint_d", "eslint" })
      end
    end,
  },
}
