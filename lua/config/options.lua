-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Force Mason to use system Node.js instead of its bundled one
vim.g.mason_use_system_node = true
vim.opt.clipboard = "unnamedplus"
vim.g.python3_host_prog = vim.fn.expand("~/.neovim-python/bin/python")
vim.opt.smoothscroll = true
