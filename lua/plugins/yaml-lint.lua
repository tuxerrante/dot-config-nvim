-- Extra CLI linters for YAML-shaped files, gated by root-marker/binary presence
-- (same `linter_condition(root_files, binary)` shape as lua/plugins/typescript.lua:52-56;
-- replicated here rather than imported since that helper is file-local there).
--
-- * actionlint + zizmor: GitHub Actions workflow files (.github/workflows/*.yml|yaml).
--   actionlint checks syntax/logic/expression correctness; zizmor is a dedicated
--   security scanner (unpinned actions, injection via `${{ }}`, excessive
--   `permissions:`, `pull_request_target` credential leakage). Unlike markdown's
--   rumdl/markdownlint-cli2 swap, these two check different things and are meant
--   to fire side by side, not replace one another. Both already ship built-in
--   linter definitions in nvim-lint (lua/lint/linters/{actionlint,zizmor}.lua) --
--   only the condition-gated wiring is new here.
-- * kubescape: Kubernetes manifests / Helm chart templates. Gated on an upward
--   Chart.yaml/kustomization.yaml, the same marker lua/plugins/helm.lua already
--   uses to detect Helm chart roots. No built-in nvim-lint definition exists for
--   kubescape, so one is defined below; its JSON report is resource-level (no
--   line/col info), so findings are anchored at line 1 of the buffer.

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

-- GitHub Actions workflows aren't gated by an upward root marker the way
-- eslint/biome configs are -- a repo's .github/ dir is upward of every file in
-- the repo, which would fire on any unrelated YAML file. Gate on the buffer's
-- own path instead, keeping the same "condition(ctx) -> boolean" shape.
local function is_gh_actions_workflow(ctx)
  return ctx.filename:match("%.github/workflows/.*%.ya?ml$") ~= nil
end

local function workflow_linter_condition(binary)
  return function(ctx)
    return is_gh_actions_workflow(ctx) and has_binary(ctx, binary)
  end
end

local function extend_unique(list, values)
  list = list or {}
  for _, value in ipairs(values) do
    if not vim.tbl_contains(list, value) then
      table.insert(list, value)
    end
  end
  return list
end

return {
  {
    "mfussenegger/nvim-lint",
    opts = function(_, opts)
      opts.linters = opts.linters or {}
      opts.linters_by_ft = opts.linters_by_ft or {}

      opts.linters.actionlint = vim.tbl_deep_extend("force", opts.linters.actionlint or {}, {
        condition = workflow_linter_condition("actionlint"),
      })

      opts.linters.zizmor = vim.tbl_deep_extend("force", opts.linters.zizmor or {}, {
        condition = workflow_linter_condition("zizmor"),
      })

      opts.linters.kubescape = vim.tbl_deep_extend("force", {
        cmd = "kubescape",
        stdin = false,
        append_fname = true,
        args = { "scan", "framework", "nsa", "--format", "json", "--format-version", "v2", "--output", "-" },
        stream = "stdout",
        ignore_exitcode = true,
        parser = function(output)
          local diagnostics = {}
          local ok, decoded = pcall(vim.json.decode, output)
          if not ok or type(decoded) ~= "table" then
            return diagnostics
          end

          for _, result in ipairs(decoded.results or {}) do
            for _, control in ipairs(result.controls or {}) do
              local status = control.status and control.status.status
              if status == "failed" then
                table.insert(diagnostics, {
                  source = "kubescape",
                  message = string.format("%s: %s", control.controlID or "?", control.name or "control failed"),
                  lnum = 0,
                  col = 0,
                  severity = vim.diagnostic.severity.WARN,
                })
              end
            end
          end

          return diagnostics
        end,
      }, opts.linters.kubescape or {})
      opts.linters.kubescape.condition = linter_condition({ "Chart.yaml", "kustomization.yaml" }, "kubescape")

      opts.linters_by_ft.yaml = extend_unique(opts.linters_by_ft.yaml, { "actionlint", "zizmor", "kubescape" })
    end,
  },
}
