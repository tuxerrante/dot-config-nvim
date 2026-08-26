return {
  {
    "nvim-lua/plenary.nvim",
    lazy = true,
    init = function()
      local actions = { "start", "stop", "status", "restart" }

      vim.api.nvim_create_user_command("LiteLLM", function(command)
        local action = command.args ~= "" and command.args or "status"
        vim.system({ "systemctl", "--user", action, "litellm.service" }, { text = true }, function(result)
          vim.schedule(function()
            local output = vim.trim((result.stdout or "") .. (result.stderr or ""))
            local level = result.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
            vim.notify(output ~= "" and output or ("LiteLLM " .. action .. " completed"), level, {
              title = "LiteLLM",
            })
          end)
        end)
      end, {
        nargs = "?",
        complete = function()
          return actions
        end,
        desc = "Manage the LiteLLM user service",
      })

      vim.api.nvim_create_user_command("Aider", function()
        local buffer_path = vim.api.nvim_buf_get_name(0)
        local start_path = buffer_path ~= "" and buffer_path or vim.fn.getcwd()
        local root = vim.fs.root(start_path, ".git")

        if root == nil then
          vim.notify("Open a file inside an existing Git repository before starting aider", vim.log.levels.ERROR, {
            title = "Aider",
          })
          return
        end

        vim.cmd("botright 20new")
        local job = vim.fn.jobstart({
          vim.fn.expand("~/.local/bin/aider-aoai"),
        }, {
          cwd = root,
          term = true,
        })
        if job <= 0 then
          vim.notify("Failed to start aider", vim.log.levels.ERROR, { title = "Aider" })
          vim.cmd("close")
          return
        end

        vim.bo.bufhidden = "wipe"
        vim.cmd("startinsert")
      end, {
        desc = "Open aider through the local AOAI proxy",
      })
    end,
  },
}
