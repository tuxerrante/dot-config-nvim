local M = {}

local function clone_list(list)
  return vim.deepcopy(list)
end

local function append_tools(base, extras)
  local merged = clone_list(base)
  vim.list_extend(merged, clone_list(extras))
  return merged
end

-- Keep structured workspace tools separate from shell-backed tools so
-- "available" and "trusted" policy stays explicit.
local WORKSPACE_TOOLS = { "buffer", "selection", "file", "glob", "grep", "gitdiff" }

M.DEFAULT_TOOLS = clone_list(WORKSPACE_TOOLS)
M.DEFAULT_TRUSTED_TOOLS = clone_list(WORKSPACE_TOOLS)
M.EDIT_TOOLS = append_tools(WORKSPACE_TOOLS, { "edit" })
M.EDIT_TRUSTED_TOOLS = clone_list(M.DEFAULT_TRUSTED_TOOLS)
M.SHELL_TOOLS = append_tools(WORKSPACE_TOOLS, { "bash_safe", "bash", "edit" })
M.SHELL_TRUSTED_TOOLS = append_tools(WORKSPACE_TOOLS, { "bash_safe" })

M.SYSTEM_PROMPT = table.concat({
  "Prefer concise answers and targeted evidence.",
  "When inspecting code, summarize or quote only the smallest relevant snippet instead of pasting entire files.",
  "Use file, glob, grep, and gitdiff for workspace inspection.",
  "The grep tool is workspace-scoped. Use bash_safe only in the explicit shell workflow when the structured workspace tools cannot express a read-only command.",
  "Only use edit when the user asked for changes or when the workflow is explicitly edit-enabled.",
}, " ")

local SAFE_COMMANDS = {
  cat = true,
  grep = true,
  ls = true,
  pwd = true,
  rg = true,
  stat = true,
}

local SAFE_GIT_SUBCOMMANDS = {
  blame = true,
  branch = true,
  diff = true,
  ["ls-files"] = true,
  log = true,
  remote = true,
  ["rev-parse"] = true,
  show = true,
  status = true,
  worktree = true,
}

local DISALLOWED_FIND_ARGS = {
  ["-delete"] = true,
  ["-exec"] = true,
  ["-execdir"] = true,
  ["-fprint"] = true,
  ["-fprint0"] = true,
  ["-fprintf"] = true,
  ["-ok"] = true,
  ["-okdir"] = true,
}

local DISALLOWED_GIT_FLAGS = {
  ["--output"] = true,
}

local ALLOWED_GIT_BRANCH_ARGS = {
  ["--list"] = true,
  ["--show-current"] = true,
  ["-a"] = true,
  ["-r"] = true,
}

local DISALLOWED_GO_TEST_FLAGS = {
  ["-c"] = true,
  ["-exec"] = true,
  ["-o"] = true,
}

local SAFE_MAKE_TARGETS = {
  fmt = true,
  ["go-verify"] = true,
  ["lint-go"] = true,
  ["test-go"] = true,
  ["unit-test-go"] = true,
  ["validate-gh-actions"] = true,
  ["validate-go"] = true,
  ["validate-go-action"] = true,
  ["validate-imports"] = true,
}

local function format_list(list)
  local keys = vim.tbl_keys(list)
  table.sort(keys)
  return table.concat(keys, ", ")
end

local function tokenize_command(command)
  local text = vim.trim(command or "")
  if text == "" then
    return nil, "Readonly shell requires a command."
  end
  if text:find("[\r\n]") then
    return nil, "Readonly shell only supports a single command line."
  end

  local argv = {}
  local current = {}
  local quote = nil
  local escaping = false

  local function push_current()
    if #current > 0 then
      table.insert(argv, table.concat(current))
      current = {}
    end
  end

  for i = 1, #text do
    local char = text:sub(i, i)
    local next_char = text:sub(i + 1, i + 1)

    if escaping then
      table.insert(current, char)
      escaping = false
    elseif quote == "'" then
      if char == "'" then
        quote = nil
      else
        table.insert(current, char)
      end
    elseif quote == '"' then
      if char == '"' then
        quote = nil
      elseif char == "\\" then
        escaping = true
      else
        table.insert(current, char)
      end
    elseif char == "'" or char == '"' then
      quote = char
    elseif char == "$" and (next_char == "(" or next_char == "{" or next_char:match("[%w_]")) then
      return nil, "Readonly shell does not invoke a shell, so variable or command expansion is unsupported."
    elseif char == "`" then
      return nil, "Readonly shell does not invoke a shell, so backtick substitution is unsupported."
    elseif char == "|" or char == "&" or char == ";" or char == "<" or char == ">" then
      return nil, "Readonly shell only supports a single direct command without shell pipes, redirection, or separators."
    elseif char == "\\" then
      escaping = true
    elseif char:match("%s") then
      push_current()
    else
      table.insert(current, char)
    end
  end

  if escaping then
    return nil, "Readonly shell command ended with an incomplete escape."
  end
  if quote then
    return nil, "Readonly shell command has an unclosed quote."
  end

  push_current()

  if #argv == 0 then
    return nil, "Readonly shell requires a command."
  end

  return argv
end

local function validate_git_branch(argv)
  if #argv == 2 then
    return argv
  end

  local arg = argv[3]
  if ALLOWED_GIT_BRANCH_ARGS[arg or ""] and (#argv == 3 or arg == "--list") then
    return argv
  end

  return nil,
    "Trusted repo shell only allows `git branch`, `git branch --show-current`, `git branch --list`, `git branch -a`, and `git branch -r`."
end

local function validate_git_remote(argv)
  if #argv == 2 then
    return argv
  end

  if #argv == 3 and argv[3] == "-v" then
    return argv
  end

  if #argv == 4 and argv[3] == "show" then
    return argv
  end

  return nil, "Trusted repo shell only allows `git remote`, `git remote -v`, and `git remote show <name>`."
end

local function validate_git_worktree(argv)
  if #argv >= 3 and argv[3] == "list" then
    return argv
  end

  return nil, "Trusted repo shell only allows `git worktree list`."
end

local function validate_git_command(argv)
  local subcommand = argv[2]
  if not SAFE_GIT_SUBCOMMANDS[subcommand or ""] then
    return nil, ("Trusted repo shell only allows git %s."):format(format_list(SAFE_GIT_SUBCOMMANDS))
  end

  if subcommand == "branch" then
    return validate_git_branch(argv)
  end
  if subcommand == "remote" then
    return validate_git_remote(argv)
  end
  if subcommand == "worktree" then
    return validate_git_worktree(argv)
  end

  for i = 3, #argv do
    local arg = argv[i]
    if DISALLOWED_GIT_FLAGS[arg] or arg:match("^%-%-output=") then
      return nil, "Trusted repo shell rejects git flags that write output files."
    end
  end

  return argv
end

local function validate_find_command(argv)
  for i = 2, #argv do
    local arg = argv[i]
    if DISALLOWED_FIND_ARGS[arg] then
      return nil, ("Trusted repo shell rejects dangerous find action %s."):format(arg)
    end
  end

  return argv
end

local function validate_go_command(argv)
  local subcommand = argv[2]
  if subcommand ~= "test" then
    return nil, "Trusted repo shell only allows `go test`."
  end

  for i = 3, #argv do
    local arg = argv[i]
    if DISALLOWED_GO_TEST_FLAGS[arg] or arg:match("^%-o=") or arg:match("^%-exec=") then
      return nil, "Trusted repo shell rejects `go test` flags that emit binaries or execute custom commands."
    end
  end

  return argv
end

local function validate_make_command(argv)
  if #argv == 2 and SAFE_MAKE_TARGETS[argv[2] or ""] then
    return argv
  end

  return nil,
    "Trusted repo shell only allows `make fmt`, `make go-verify`, `make lint-go`, `make test-go`, `make unit-test-go`, `make validate-gh-actions`, `make validate-go`, `make validate-go-action`, and `make validate-imports`."
end

function M.split_safe_command(command)
  local argv, err = tokenize_command(command)
  if not argv then
    return nil, err
  end

  local cmd = argv[1]
  if cmd == "git" then
    return validate_git_command(argv)
  end
  if cmd == "find" then
    return validate_find_command(argv)
  end
  if cmd == "go" then
    return validate_go_command(argv)
  end
  if cmd == "make" then
    return validate_make_command(argv)
  end
  if SAFE_COMMANDS[cmd] then
    return argv
  end

  return nil,
    "Trusted repo shell only allows cat, find, go test, grep, git read/list commands, ls, selected validation/test make targets, pwd, rg, and stat."
end

local function filename_same(left, right)
  return require("CopilotChat.utils.files").filename_same(left, right)
end

local function is_absolute_path(path)
  return type(path) == "string" and path:sub(1, 1) == "/"
end

local function candidate_filenames(filename, cwd)
  local candidates = {}

  local function add(path)
    if not path or path == "" then
      return
    end

    local normalized = vim.fs.normalize(path)
    candidates[normalized] = true

    local realpath = vim.uv.fs_realpath(path)
    if realpath and realpath ~= "" then
      candidates[vim.fs.normalize(realpath)] = true
    end
  end

  add(filename)

  if cwd and filename and not is_absolute_path(filename) then
    add(vim.fs.joinpath(cwd, filename))
  end

  return candidates
end

function M.find_matching_buffer(filename, cwd)
  local candidates = candidate_filenames(filename, cwd)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local buffer_name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_valid(buf) and filename_same(buffer_name, filename) then
      return buf
    end
    if vim.api.nvim_buf_is_valid(buf) then
      local buffer_candidates = candidate_filenames(buffer_name)
      for candidate in pairs(buffer_candidates) do
        if candidates[candidate] then
          return buf
        end
      end
    end
  end
end

function M.write_buffer_or_error(bufnr)
  if not bufnr or bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  if vim.bo[bufnr].buftype ~= "" or not vim.bo[bufnr].modified then
    return
  end

  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("silent write")
  end)
  if not ok then
    error(("Applied diff but failed to save %s: %s"):format(vim.api.nvim_buf_get_name(bufnr), err))
  end
end

local function patch_bash_safe(config)
  local bash = config.functions.bash
  if not bash or config._aaff_safe_bash_patched then
    return
  end

  local safe_function = {
    group = bash.group,
    description = "Executes a constrained read-only command without invoking a shell. Reserve it for explicit shell workflows when workspace tools cannot express the inspection.",
    schema = bash.schema,
    trusted = true,
    resolve = function(input, source)
      local argv, err = M.split_safe_command(input.command)
      if not argv then
        error(err .. " Use the shell workflow for complex bash.")
      end

      local out = require("CopilotChat.utils").system(argv, source.cwd())
      if out.code ~= 0 then
        error(
          vim.trim(out.stderr or "") ~= "" and vim.trim(out.stderr)
            or ("Trusted repo command failed: " .. input.command)
        )
      end

      return {
        {
          data = out.stdout or "",
        },
      }
    end,
  }

  config.functions.bash_safe = safe_function
  config.functions.bash_ro = config.functions.bash_ro
    or vim.tbl_extend("force", {}, safe_function, {
      description = "Alias for bash_safe.",
    })
  config._aaff_safe_bash_patched = true
end

local function patch_edit_autosave(config)
  local edit = config.functions.edit
  if not edit or edit._aaff_autosave_patched then
    return
  end

  local original_edit_resolve = edit.resolve
  edit.resolve = function(input, source)
    local result = original_edit_resolve(input, source)
    M.write_buffer_or_error(M.find_matching_buffer(input.filename, source and source.cwd and source.cwd()))
    return result
  end
  edit._aaff_autosave_patched = true
end

local function patch_accept_diff_autosave(config)
  local accept_diff = config.mappings and config.mappings.accept_diff
  if not accept_diff or accept_diff._aaff_autosave_patched then
    return
  end

  local constants = require("CopilotChat.constants")
  local original_accept_diff = accept_diff.callback
  accept_diff.callback = function(source)
    local block = require("CopilotChat").chat:get_block(constants.ROLE.ASSISTANT, true)
    original_accept_diff(source)
    if block and block.header and block.header.filename then
      M.write_buffer_or_error(M.find_matching_buffer(block.header.filename, source and source.cwd and source.cwd()))
    end
  end
  accept_diff._aaff_autosave_patched = true
end

function M.patch_config(config)
  config = config or require("CopilotChat.config")
  if config._aaff_runtime_patched then
    return
  end

  patch_bash_safe(config)
  patch_edit_autosave(config)
  patch_accept_diff_autosave(config)

  config._aaff_runtime_patched = true
end

return M
