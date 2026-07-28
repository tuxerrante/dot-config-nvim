local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vim.env.HOME .. "/.local/share/nvim/lazy/plenary.nvim")
vim.opt.runtimepath:prepend(vim.env.HOME .. "/.local/share/nvim/lazy/CopilotChat.nvim")

vim.opt.swapfile = false
vim.opt.writebackup = false
