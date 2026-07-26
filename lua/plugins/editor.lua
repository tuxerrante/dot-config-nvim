return {
  {
    "folke/snacks.nvim",
    opts = {
      picker = {
        -- Enable hidden files by default for all pickers
        sources = {
          files = {
            hidden = true,
            ignored = false,
          },
          grep = {
            hidden = true,
            ignored = false,
          },
          grep_word = {
            hidden = true,
            ignored = false,
          },
        },
      },
    },
  },
}
