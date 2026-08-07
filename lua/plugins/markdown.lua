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

  -- Keep Markdown lint diagnostics independent from explicit formatting.
  {
    "mfussenegger/nvim-lint",
    opts = {
      linters_by_ft = {
        markdown = { "markdownlint-cli2" },
      },
    },
  },
}
