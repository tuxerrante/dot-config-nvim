return {
  -- Disable markdownlint auto-formatting on save
  -- This prevents automatic changes to markdown files
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        -- Remove markdown formatters (or set to empty)
        -- markdown = {},
        -- ["markdown.mdx"] = {},
      },
    },
  },

  -- Optionally: keep linting diagnostics but disable auto-fix
  -- Uncomment below if you still want to see warnings without auto-fix
  {
    "mfussenegger/nvim-lint",
    opts = {
      linters_by_ft = {
        markdown = { "markdownlint-cli2" },
      },
    },
  },
}
