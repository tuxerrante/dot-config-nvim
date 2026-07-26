return {
  -- lighter tokyonight variants
  { "folke/tokyonight.nvim", opts = { style = "moon" } },

  -- popular alternatives (from lighter to darker)
  { "catppuccin/nvim", name = "catppuccin" }, -- "latte" (light), "frappe", "macchiato", "mocha"
  { "rose-pine/neovim", name = "rose-pine" }, -- soft, muted palette
  { "rebelot/kanagawa.nvim" }, -- warm, earthy tones
  { "EdenEast/nightfox.nvim" }, -- includes "dayfox" (light) and "dawnfox"
  { "ellisonleao/gruvbox.nvim" }, -- classic warm retro theme

  -- set your default
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "catppuccin-frappe", -- change this to try different ones
    },
  },
}
