return {
  {
    "nvim-neotest/neotest",
    optional = true,
    opts = function(_, opts)
      local progress = require("progress_notifier")
      opts.adapters = opts.adapters or {}
      opts.adapters["neotest-golang"] = vim.tbl_deep_extend("force", opts.adapters["neotest-golang"] or {}, {
        warn_test_name_dupes = false,
      })

      opts.consumers = opts.consumers or {}
      opts.consumers.aaff_notifier = function(client)
        client.listeners.run = function(_, _, position_ids)
          local total = vim.tbl_count(position_ids or {})
          local label = total > 0 and ("running %d test(s)"):format(total) or "running tests"
          progress.start("neotest", "Neotest", label, vim.log.levels.INFO)
        end

        client.listeners.results = function(_, results, partial)
          local counts = {
            passed = 0,
            failed = 0,
            skipped = 0,
            running = 0,
          }

          for _, result in pairs(results or {}) do
            if counts[result.status] ~= nil then
              counts[result.status] = counts[result.status] + 1
            end
          end

          if partial or counts.running > 0 then
            local active = counts.running > 0 and counts.running or (counts.passed + counts.failed + counts.skipped)
            progress.update("neotest", ("running %d test result(s)"):format(active), vim.log.levels.INFO)
            return
          end

          local total = counts.passed + counts.failed + counts.skipped
          local level = counts.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO
          local icon = counts.failed > 0 and "[warn]" or "[ok]"
          progress.stop(
            "neotest",
            ("Neotest: %d passed, %d failed, %d skipped"):format(counts.passed, counts.failed, counts.skipped),
            level,
            icon
          )

          if total == 0 then
            progress.stop("neotest", "Neotest finished with no reported results", vim.log.levels.INFO, "[ok]")
          end
        end
      end
    end,
  },
}
