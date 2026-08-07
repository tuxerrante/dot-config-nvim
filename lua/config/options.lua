-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Force Mason to use system Node.js instead of its bundled one
vim.g.mason_use_system_node = true

local linuxbrew_bin = "/home/linuxbrew/.linuxbrew/bin"
if vim.fn.isdirectory(linuxbrew_bin) == 1 and not vim.env.PATH:find(linuxbrew_bin, 1, true) then
  vim.env.PATH = linuxbrew_bin .. ":" .. vim.env.PATH
end

vim.opt.clipboard = "unnamedplus"
vim.g.python3_host_prog = vim.fn.expand("~/.neovim-python/bin/python")
vim.opt.smoothscroll = true
