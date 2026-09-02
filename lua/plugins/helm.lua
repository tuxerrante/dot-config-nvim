-- helm-ls: LSP for Helm charts (tree-sitter based, Go).
-- Provides go-to-definition from `.Values.x` in templates/*.yaml to values.yaml,
-- document symbols (outline, `cs` via aerial/navic), hover, completion, diagnostics.
-- yamlls is disabled for chart template files to avoid noise on Go-template syntax.
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        helm_ls = {
          settings = {
            ["helm-ls"] = {
              yamlls = {
                enabled = true, -- delegate plain YAML validation/schema to yamlls under the hood
                path = "yaml-language-server",
              },
            },
          },
        },
        yamlls = {
          -- Don't let yamlls take over Helm chart templates (they contain Go template
          -- syntax that isn't valid YAML); helm_ls handles those instead.
          on_new_config = function(new_config, new_root_dir)
            if new_root_dir:match("charts") or vim.fn.glob(new_root_dir .. "/Chart.yaml") ~= "" then
              new_config.filetypes = vim.tbl_filter(function(ft)
                return ft ~= "helm"
              end, new_config.filetypes or {})
            end
          end,
        },
      },
    },
  },

  -- helm_ls and yamlls are auto-installed by Mason: LazyVim's lsp/init.lua
  -- ensures any server declared under `servers` here gets installed via
  -- mason-lspconfig automatically (as long as it's mapped in the registry,
  -- which both helm_ls -> helm-ls and yamlls -> yaml-language-server are).
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "yaml", "helm" } },
  },

  -- aerial.nvim is already configured in plugins/aerial.lua; it will pick up
  -- helm_ls document symbols automatically (use its existing outline keymap,
  -- e.g. <leader>cs, to jump around deployment.yaml's main objects).
}
