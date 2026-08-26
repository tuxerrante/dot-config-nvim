local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      (message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual)
    )
  end
end

local function plugin_spec(name)
  package.loaded["plugins.markdown"] = nil

  for _, spec in ipairs(require("plugins.markdown")) do
    if spec[1] == name then
      return spec
    end
  end

  error(("plugin spec not found: %s"):format(name))
end

local function test_rumdl_is_the_only_markdown_linter()
  local spec = plugin_spec("mfussenegger/nvim-lint")
  local opts = { linters_by_ft = { markdown = { "markdownlint-cli2" } } }
  spec.opts(nil, opts)

  assert_equal(opts.linters_by_ft.markdown, {}, "Markdown CLI linting should be disabled in favor of rumdl LSP")
  assert_equal(opts.linters_by_ft["markdown.mdx"], {}, "MDX CLI linting should be disabled in favor of rumdl LSP")
end

local function test_rumdl_lsp_honors_repo_configs_without_overlapping_marksman()
  local spec = plugin_spec("neovim/nvim-lspconfig")
  local rumdl = spec.opts.servers.rumdl

  assert_equal(rumdl.mason, false, "rumdl should use the binary from PATH")
  assert_equal(rumdl.filetypes, { "markdown", "markdown.mdx" }, "rumdl should cover Markdown and MDX")
  assert(vim.tbl_contains(rumdl.root_markers, ".markdownlint.jsonc"), "rumdl should recognize repo JSONC configs")
  assert_equal(rumdl.init_options.enableLinkCompletions, false, "Marksman should own link completion")
  assert_equal(rumdl.init_options.enableLinkNavigation, false, "Marksman should own link navigation")
  assert_equal(rumdl.init_options.enableSymbols, false, "Marksman should own document symbols")
end

function M.run()
  test_rumdl_is_the_only_markdown_linter()
  test_rumdl_lsp_honors_repo_configs_without_overlapping_marksman()
  print("PASS markdown_plugin_spec")
end

return M
