-- Git worktrees live under <repo>/.worktrees and are not gitignored, so
-- hidden = true makes every picker return one hit per worktree copy.
local worktree_exclude = { ".worktrees" }

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
            exclude = worktree_exclude,
          },
          grep = {
            hidden = true,
            ignored = false,
            exclude = worktree_exclude,
          },
          grep_word = {
            hidden = true,
            ignored = false,
            exclude = worktree_exclude,
          },
        },
      },
    },
    -- <leader>ff / <leader>sg stay on the current checkout; these include .worktrees.
    keys = {
      {
        "<leader>fW",
        function()
          Snacks.picker.files({ exclude = {} })
        end,
        desc = "Find Files (incl. worktrees)",
      },
      {
        "<leader>fG",
        function()
          Snacks.picker.grep({ exclude = {} })
        end,
        desc = "Grep (incl. worktrees)",
      },
    },
  },
}
