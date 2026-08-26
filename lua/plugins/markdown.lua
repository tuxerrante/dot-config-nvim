return {
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        markdown = { "prettier" },
        ["markdown.mdx"] = { "prettier" },
      },
    },
  },
  {
    "mfussenegger/nvim-lint",
    opts = function(_, opts)
      opts.linters_by_ft = opts.linters_by_ft or {}
      opts.linters_by_ft.markdown = {}
      opts.linters_by_ft["markdown.mdx"] = {}
    end,
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        rumdl = {
          mason = false,
          filetypes = { "markdown", "markdown.mdx" },
          root_markers = {
            ".rumdl.toml",
            "rumdl.toml",
            "pyproject.toml",
            ".markdownlint-cli2.json",
            ".markdownlint-cli2.jsonc",
            ".markdownlint-cli2.yaml",
            ".markdownlint-cli2.yml",
            ".markdownlint.json",
            ".markdownlint.jsonc",
            ".markdownlint.yaml",
            ".markdownlint.yml",
            ".git",
          },
          init_options = {
            enableLinkCompletions = false,
            enableLinkNavigation = false,
            enableSymbols = false,
          },
        },
      },
    },
  },
}
