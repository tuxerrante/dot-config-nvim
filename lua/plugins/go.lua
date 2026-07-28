return {
  {
    "mfussenegger/nvim-lint",
    optional = true,
    init = function()
      local progress = require("progress_notifier")

      local function go_module_root(dirname)
        local out = vim.system({ "go", "env", "GOMOD" }, { cwd = dirname, text = true }):wait()
        if out.code ~= 0 then
          return nil
        end

        local gomod = vim.trim(out.stdout or "")
        if gomod == "" or gomod == "/dev/null" then
          return nil
        end

        return vim.fn.fnamemodify(gomod, ":h")
      end

      local function golangcilint_target(scope)
        local filename = vim.api.nvim_buf_get_name(0)
        if filename == "" then
          return nil
        end

        local dirname = vim.fn.fnamemodify(filename, ":h")
        if scope == "file" then
          return filename
        end
        if scope == "repo" then
          return go_module_root(dirname) or dirname
        end

        return dirname
      end

      local function wrap_golangcilint(linter, target, scope)
        linter.args = vim.deepcopy(linter.args or {})
        if type(linter.args[#linter.args]) == "function" then
          linter.args[#linter.args] = target
        else
          table.insert(linter.args, target)
        end

        if type(linter.parser) == "function" then
          local original_parser = linter.parser
          linter.parser = function(output, bufnr, cwd)
            local diagnostics = original_parser(output, bufnr, cwd)
            vim.schedule(function()
              local level = #diagnostics > 0 and vim.log.levels.WARN or vim.log.levels.INFO
              local icon = #diagnostics > 0 and "[warn]" or "[ok]"
              progress.stop("golint", ("GoLint(%s): %d issue(s)"):format(scope, #diagnostics), level, icon)
            end)
            return diagnostics
          end
        end

        return linter
      end

      vim.api.nvim_create_user_command("GoLint", function(cmd)
        local ok, lint = pcall(require, "lint")
        if not ok then
          return
        end

        local scope = cmd.args ~= "" and cmd.args or "pkg"
        if not vim.tbl_contains({ "file", "pkg", "repo" }, scope) then
          vim.notify("GoLint expects one of: file, pkg, repo", vim.log.levels.ERROR)
          return
        end

        local target = golangcilint_target(scope)
        if not target then
          vim.notify("GoLint could not resolve a target for the current buffer", vim.log.levels.ERROR)
          return
        end

        progress.start("golint", "GoLint", ("running %s"):format(scope), vim.log.levels.INFO)

        local ok_try, err = pcall(lint.try_lint, { "golangcilint" }, {
          wrap_linter = function(linter)
            return wrap_golangcilint(linter, target, scope)
          end,
        })

        if not ok_try then
          progress.stop("golint", "GoLint failed to start", vim.log.levels.ERROR, "")
          error(err)
        end
      end, {
        nargs = "?",
        complete = function()
          return { "file", "pkg", "repo" }
        end,
        desc = "Run golangci-lint for current file, package, or repo",
      })
    end,
    opts = function(_, opts)
      opts.linters_by_ft = opts.linters_by_ft or {}
      opts.linters_by_ft.go = {}
    end,
  },
}
