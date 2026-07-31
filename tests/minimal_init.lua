local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local data_root = vim.fn.stdpath("data")

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vim.fs.joinpath(data_root, "lazy", "plenary.nvim"))
vim.opt.runtimepath:prepend(vim.fs.joinpath(data_root, "lazy", "CopilotChat.nvim"))

vim.opt.swapfile = false
vim.opt.writebackup = false
