-- CodeCompanion: chat + inline assistant, using the Copilot adapter so it
-- rides on the same GitHub Copilot auth as copilot.lua / CopilotChat.nvim
-- (no extra API keys needed). Kept on a separate <leader>C prefix so it
-- doesn't collide with CopilotChat's <leader>a mappings in copilot.lua.
return {
  {
    "olimorris/codecompanion.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
    },
    cmd = {
      "CodeCompanion",
      "CodeCompanionChat",
      "CodeCompanionActions",
      "CodeCompanionCmd",
    },
    keys = {
      {
        "<leader>Cc",
        "<cmd>CodeCompanionChat Toggle<cr>",
        desc = "Toggle CodeCompanion Chat",
        mode = { "n", "v" },
      },
      {
        "<leader>Ca",
        "<cmd>CodeCompanionActions<cr>",
        desc = "CodeCompanion Actions",
        mode = { "n", "v" },
      },
      {
        "<leader>Ci",
        "<cmd>CodeCompanion<cr>",
        desc = "CodeCompanion Inline Prompt",
        mode = { "n", "v" },
      },
      {
        "<leader>Cx",
        "<cmd>CodeCompanionChat Add<cr>",
        desc = "Add Selection To CodeCompanion Chat",
        mode = "v",
      },
    },
    opts = {
      strategies = {
        chat = { adapter = "copilot" },
        inline = { adapter = "copilot" },
        cmd = { adapter = "copilot" },
      },
      display = {
        chat = {
          show_settings = true,
        },
      },
    },
  },
  -- CodeCompanion's chat buffer renders best with markdown rendering enabled
  -- for its filetype; render-markdown.nvim is already pulled in by the
  -- markdown lang extra, so just extend its file_types.
  {
    "MeanderingProgrammer/render-markdown.nvim",
    optional = true,
    opts = function(_, opts)
      opts.file_types = opts.file_types or {}
      vim.list_extend(opts.file_types, { "codecompanion" })
    end,
  },
  {
    "saghen/blink.cmp",
    optional = true,
    opts = function(_, opts)
      -- Disable blink's default sources inside CodeCompanion's chat buffer.
      opts = opts or {}
      opts.sources = opts.sources or {}
      opts.sources.per_filetype = opts.sources.per_filetype or {}
      opts.sources.per_filetype["codecompanion"] = {}
    end,
  },
}
