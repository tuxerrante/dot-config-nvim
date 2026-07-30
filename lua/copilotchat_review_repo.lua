local M = {}

local function trim(text)
  return vim.trim(text or "")
end

local function normalized_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local realpath = vim.uv.fs_realpath(path)
  return vim.fs.normalize(realpath or path)
end

local function run_git(cwd, args)
  local command = { "git", "-C", cwd }
  vim.list_extend(command, args)

  local result = vim.system(command, { text = true }):wait()
  if result.code ~= 0 then
    local detail = trim(result.stderr)
    if detail == "" then
      detail = trim(result.stdout)
    end
    if detail == "" then
      detail = "git command failed"
    end
    return nil, detail
  end

  return trim(result.stdout), nil
end

local function repo_root_for_path(path, source_kind)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local cwd = path
  if source_kind == "buffer" then
    cwd = vim.fs.dirname(path)
  end

  local root, err = run_git(cwd, { "rev-parse", "--show-toplevel" })
  if err or root == "" then
    return nil
  end

  return normalized_path(root)
end

local function pr_owner_repo(pr)
  if pr.owner_repo and pr.owner_repo ~= "" then
    return pr.owner_repo, nil
  end

  if pr.owner and pr.repo then
    return pr.owner .. "/" .. pr.repo, nil
  end

  return nil, "PR metadata is missing owner/repo."
end

local function list_candidate_paths()
  local candidates = {}
  local seen = {}

  local function add(path, source_kind)
    if type(path) ~= "string" or path == "" then
      return
    end

    local normalized = normalized_path(path) or vim.fs.normalize(path)
    if seen[normalized] then
      return
    end
    seen[normalized] = true
    table.insert(candidates, {
      path = path,
      source_kind = source_kind,
    })
  end

  add(vim.uv.cwd(), "cwd")

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    add(vim.api.nvim_buf_get_name(bufnr), "buffer")
  end

  return candidates
end

local function complete(callback, result, err)
  if callback then
    callback(result, err)
    return nil, nil
  end

  return result, err
end

local function prompt_repo_choice(expected, matches, callback)
  if not callback then
    return nil, "repo selection requires an async callback"
  end

  vim.ui.select(matches, {
    prompt = ("Multiple local checkouts match %s"):format(expected),
    format_item = function(item)
      return item.repo_root
    end,
  }, function(item)
    if not item then
      callback(nil, "repo selection cancelled")
      return
    end

    callback(item, nil)
  end)

  return nil, nil
end

local function prompt_repo_path(expected, callback)
  if not callback then
    return nil, "repo selection requires an async callback"
  end

  vim.ui.input({
    prompt = ("No local checkout matched %s. Enter a repo path or leave blank to cancel: "):format(expected),
    completion = "dir",
  }, function(value)
    if type(value) ~= "string" or trim(value) == "" then
      callback(nil, "repo selection cancelled")
      return
    end

    callback(trim(value), nil)
  end)

  return nil, nil
end

local function prompt_dirty_worktree(target, callback)
  if not callback then
    return nil, "dirty worktree selection requires an async callback"
  end

  vim.ui.select({ "reuse existing worktree", "cancel" }, {
    prompt = ("PR worktree has local changes: %s"):format(target),
  }, function(choice)
    if choice ~= "reuse existing worktree" then
      callback(nil, "worktree selection cancelled")
      return
    end

    callback(choice, nil)
  end)

  return nil, nil
end

local function parse_worktree_list(text)
  local entries = {}
  local current = nil

  for line in (text or ""):gmatch("[^\n]+") do
    if line == "" then
      current = nil
    else
      local path = line:match("^worktree%s+(.+)$")
      if path then
        current = {
          path = normalized_path(path) or vim.fs.normalize(path),
          detached = false,
        }
        table.insert(entries, current)
      elseif current and line == "detached" then
        current.detached = true
      elseif current then
        local key, value = line:match("^(%S+)%s+(.+)$")
        if key and value then
          current[key] = value
        end
      end
    end
  end

  return entries
end

local function list_worktrees(repo_root)
  local output, err = run_git(repo_root, { "worktree", "list", "--porcelain" })
  if err then
    return nil, ("Failed to inspect git worktrees for %s: %s"):format(repo_root, err)
  end

  local entries = parse_worktree_list(output)
  if #entries == 0 then
    return nil, ("Could not determine git worktrees for %s"):format(repo_root)
  end

  return entries, nil
end

function M.parse_pr_url(pr_url)
  if type(pr_url) ~= "string" then
    return nil, "Expected a GitHub pull request URL."
  end

  local owner, repo, number = pr_url:match("^https?://github%.com/([^/]+)/([^/]+)/pull/(%d+)/?$")
  if not owner then
    return nil, ("Expected a GitHub pull request URL, got %q."):format(pr_url)
  end

  local normalized = ("https://github.com/%s/%s/pull/%s"):format(owner, repo, number)
  return {
    owner = owner,
    repo = repo,
    number = tonumber(number),
    owner_repo = owner .. "/" .. repo,
    url = normalized,
  }, nil
end

function M.normalize_github_remote(remote_url)
  if type(remote_url) ~= "string" or remote_url == "" then
    return nil
  end

  local normalized = trim(remote_url):gsub("/+$", "")
  normalized = normalized:gsub("%.git$", "")

  local owner, repo = normalized:match("^https://github%.com/([^/]+)/([^/]+)$")
  if not owner then
    owner, repo = normalized:match("^http://github%.com/([^/]+)/([^/]+)$")
  end
  if not owner then
    owner, repo = normalized:match("^git@github%.com:([^/]+)/([^/]+)$")
  end
  if not owner then
    owner, repo = normalized:match("^ssh://git@github%.com/([^/]+)/([^/]+)$")
  end

  if not owner then
    return nil
  end

  return owner .. "/" .. repo
end

local function validate_manual_repo_path(expected, manual_path)
  local manual_root = repo_root_for_path(trim(manual_path), "cwd")
  if not manual_root then
    return nil, ("Selected path %s is not inside a git checkout."):format(trim(manual_path))
  end

  local remote_url = run_git(manual_root, { "remote", "get-url", "origin" })
  local owner_repo = M.normalize_github_remote(remote_url)
  if owner_repo ~= expected then
    return nil, ("Selected repo origin %s does not match GitHub repo %s."):format(owner_repo or "unknown", expected)
  end

  return {
    repo_root = manual_root,
    owner_repo = owner_repo,
  }, nil
end

function M.select_repo_root(pr, callback)
  local expected, expected_err = pr_owner_repo(pr)
  if expected_err then
    return nil, expected_err
  end

  local checked_roots = {}
  local matches = {}

  for _, candidate in ipairs(list_candidate_paths()) do
    local root = repo_root_for_path(candidate.path, candidate.source_kind)
    if root and not checked_roots[root] then
      checked_roots[root] = true

      local remote_url = run_git(root, { "remote", "get-url", "origin" })
      local owner_repo = M.normalize_github_remote(remote_url)
      if owner_repo == expected then
        table.insert(matches, {
          repo_root = root,
          owner_repo = owner_repo,
        })
      end
    end
  end

  if #matches == 1 then
    return complete(callback, matches[1], nil)
  end

  if #matches > 1 then
    return prompt_repo_choice(expected, matches, callback)
  end

  if not callback then
    return nil, "repo selection requires an async callback"
  end

  return prompt_repo_path(expected, function(manual_path, prompt_err)
    if prompt_err then
      callback(nil, prompt_err)
      return
    end

    local result, err = validate_manual_repo_path(expected, manual_path)
    callback(result, err)
  end)
end

function M.resolve_primary_checkout(repo_root)
  local entries, err = list_worktrees(repo_root)
  if err then
    return nil, err
  end

  return entries[1].path, nil
end

local function build_worktree_result(repo_root, primary, target_normalized, owner_repo, pr)
  return {
    repo_root = repo_root,
    primary_root = primary,
    worktree_root = target_normalized,
    owner_repo = owner_repo,
    pr = pr,
  }
end

function M.ensure_pr_worktree(pr, repo_root, callback)
  local primary, primary_err = M.resolve_primary_checkout(repo_root)
  if primary_err then
    return nil, primary_err
  end

  local owner_repo, owner_repo_err = pr_owner_repo(pr)
  if owner_repo_err then
    return nil, owner_repo_err
  end

  local pr_number = tonumber(pr and pr.number)
  if not pr_number then
    return nil, "PR number is required."
  end

  local target = vim.fs.joinpath(primary, ".worktrees", ("pr-%d"):format(pr_number))
  local target_normalized = normalized_path(target) or vim.fs.normalize(target)

  local worktrees, worktrees_err = list_worktrees(repo_root)
  if worktrees_err then
    return nil, worktrees_err
  end

  local registered = nil
  for _, entry in ipairs(worktrees) do
    if entry.path == target_normalized then
      registered = entry
      break
    end
  end

  if vim.uv.fs_stat(target) and not registered then
    return nil, ("Worktree path %s exists on disk but is not a registered git worktree."):format(target)
  end

  local _, fetch_err = run_git(primary, { "fetch", "origin", ("pull/%d/head"):format(pr_number) })
  if fetch_err then
    return nil, ("Failed to fetch PR #%d: %s"):format(pr_number, fetch_err)
  end

  local fetch_head, fetch_head_err = run_git(primary, { "rev-parse", "FETCH_HEAD" })
  if fetch_head_err then
    return nil, ("Failed to resolve FETCH_HEAD for PR #%d: %s"):format(pr_number, fetch_head_err)
  end

  if not registered then
    local _, add_err = run_git(primary, { "worktree", "add", "--detach", target, "FETCH_HEAD" })
    if add_err then
      return nil, ("Failed to create PR worktree at %s: %s"):format(target, add_err)
    end
    return complete(callback, build_worktree_result(repo_root, primary, target_normalized, owner_repo, pr), nil)
  end

  local status, status_err = run_git(target, { "status", "--porcelain" })
  if status_err then
    return nil, ("Failed to inspect existing PR worktree at %s: %s"):format(target, status_err)
  end
  if status ~= "" then
    if not callback then
      return nil, "dirty worktree selection requires an async callback"
    end

    return prompt_dirty_worktree(target, function(_, prompt_err)
      if prompt_err then
        callback(nil, prompt_err)
        return
      end

      callback(build_worktree_result(repo_root, primary, target_normalized, owner_repo, pr), nil)
    end)
  end

  local current_head, head_err = run_git(target, { "rev-parse", "HEAD" })
  if head_err then
    return nil, ("Failed to inspect existing PR worktree HEAD at %s: %s"):format(target, head_err)
  end

  if current_head ~= fetch_head then
    local _, checkout_err = run_git(target, { "checkout", "--detach", fetch_head })
    if checkout_err then
      return nil, ("Failed to update existing PR worktree at %s: %s"):format(target, checkout_err)
    end
  end

  return complete(callback, build_worktree_result(repo_root, primary, target_normalized, owner_repo, pr), nil)
end

return M
