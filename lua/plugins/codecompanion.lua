-- CodeCompanion: chat + inline assistant, using the LiteLLM OpenAI-compatible
-- endpoint. Nested under LazyVim's existing "+ai" <leader>a group as its own
-- <leader>aC subgroup.
local function litellm_adapter()
  local adapter = require("codecompanion.adapters").extend("openai_compatible", {
    env = {
      api_key = "cmd:awk -F= '$1 == \"LITELLM_MASTER_KEY\" { print substr($0, index($0, \"=\") + 1) }' \"$HOME/.config/litellm/.env\"",
      url = "cmd:awk -F= '$1 == \"LITELLM_BASE_URL\" { print substr($0, index($0, \"=\") + 1) }' \"$HOME/.config/litellm/.env\"",
      chat_url = "/v1/chat/completions",
      models_endpoint = "/v1/models",
    },
    headers = {
      ["Content-Type"] = "application/json",
      Authorization = ("Bearer " .. "${api_key}"),
    },
    schema = {
      model = {
        default = function()
          local model = vim.env.LITELLM_DEFAULT_MODEL
          return model and model ~= "" and model or "code"
        end,
      },
    },
  })

  return adapter
end

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
      { "<leader>aC", "", desc = "+codecompanion", mode = { "n", "v" } },
      {
        "<leader>aCc",
        "<cmd>CodeCompanionChat Toggle<cr>",
        desc = "Toggle CodeCompanion Chat",
        mode = { "n", "v" },
      },
      {
        "<leader>aCa",
        "<cmd>CodeCompanionActions<cr>",
        desc = "CodeCompanion Actions",
        mode = { "n", "v" },
      },
      {
        "<leader>aCi",
        "<cmd>CodeCompanion<cr>",
        desc = "CodeCompanion Inline Prompt",
        mode = { "n", "v" },
      },
      {
        "<leader>aCx",
        "<cmd>CodeCompanionChat Add<cr>",
        desc = "Add Selection To CodeCompanion Chat",
        mode = "v",
      },
    },
    opts = {
      adapters = {
        http = {
          litellm = litellm_adapter,
        },
      },
      strategies = {
        chat = { adapter = "litellm" },
        inline = { adapter = "litellm" },
        cmd = { adapter = "litellm" },
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
