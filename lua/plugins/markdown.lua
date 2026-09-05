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

  -- rumdl: LSP-based Markdown linter (Mason: `rumdl`, lspconfig server `rumdl`).
  -- Replaces markdownlint-cli2 as the sole markdown linter -- running both
  -- produced duplicate/conflicting diagnostics on the same buffer. Formatting is
  -- untouched: conform.nvim/prettier above always wins over LSP-provided
  -- formatting, so rumdl's own formatter never engages as long as nothing calls
  -- vim.lsp.buf.format() directly for markdown buffers.
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        rumdl = {},
      },
    },
  },

  -- NOTE: LazyVim's own `lang.markdown` extra (extras/lang/markdown.lua) sets
  -- linters_by_ft.markdown = { "markdownlint-cli2" } as its baseline default.
  -- Removing our own prior override of that key is not enough by itself -- the
  -- extra's default reasserts itself -- so it must be explicitly emptied here to
  -- actually stop markdownlint-cli2 from firing alongside rumdl.
  {
    "mfussenegger/nvim-lint",
    opts = {
      linters_by_ft = {
        markdown = {},
      },
    },
  },
}
