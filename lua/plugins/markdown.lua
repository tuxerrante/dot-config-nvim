return {
  -- Use the Homebrew-provided Prettier formatter for explicit LazyFormat runs.
  {
    "stevearc/conform.nvim",
    init = function()
      vim.api.nvim_create_user_command("LazyFormat", function()
        require("conform").format({ async = false, lsp_format = "fallback" })
      end, { desc = "Format the current buffer with Conform" })
    end,
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
