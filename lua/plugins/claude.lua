return {
  {
    "coder/claudecode.nvim",
    -- :PrepReview must exist before claudecode.nvim has loaded; it starts the
    -- Claude Code session itself when none is running.
    init = function()
      require("review_prep").setup()
    end,
    opts = {
      -- Tell the plugin where your claude binary is if not in standard path
      -- Since you have it in zshrc, it should work, but explicit is safer:
      -- cmd = "claude",
    },
    keys = {
      { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude Code" },
      { "<leader>at", "<cmd>ClaudeCodeTask<cr>", desc = "Claude Task" },
    },
  },
}
