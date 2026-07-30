local M = {}

local function normalized_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

local function path_exists(path)
  return vim.uv.fs_lstat(path) ~= nil
end

local function ensure_parent_dir(path)
  local parent = vim.fs.dirname(path)
  if not parent or parent == "" or parent == "." or vim.uv.fs_stat(parent) then
    return true, nil
  end

  local ok, err = ensure_parent_dir(parent)
  if not ok then
    return nil, err
  end

  local made, mkdir_err = vim.uv.fs_mkdir(parent, 493)
  if made or (mkdir_err and mkdir_err:match("exist")) then
    return true, nil
  end

  return nil, mkdir_err or ("failed to create directory " .. parent)
end

local function resolve_link_target(target, link_path)
  if not link_path then
    return nil
  end

  if link_path:sub(1, 1) == "/" then
    return normalized_path(link_path)
  end

  return normalized_path(vim.fs.joinpath(vim.fs.dirname(target), link_path))
end

local function is_same_symlink(target, source)
  local stat = vim.uv.fs_lstat(target)
  if not stat or stat.type ~= "link" then
    return false
  end

  local link_path = vim.uv.fs_readlink(target)
  if not link_path then
    return false
  end

  return resolve_link_target(target, link_path) == normalized_path(source)
end

function M.validate_allowlist_entry(entry)
  if type(entry) ~= "string" or entry == "" then
    return nil, "allowlist entries must be repo-relative file paths"
  end

  if entry:sub(1, 1) == "/" or entry:sub(-1) == "/" then
    return nil, "allowlist entries must be repo-relative file paths"
  end

  if entry:find("%*") or entry:find("%?") or entry:find("%[") then
    return nil, "allowlist entries must be repo-relative file paths"
  end

  for segment in entry:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      return nil, "allowlist entries must be repo-relative file paths"
    end
  end

  return true, nil
end

function M.bootstrap(primary_root, target_root, allowlist)
  local result = {
    linked = {},
    reused = {},
    skipped_missing = {},
  }

  primary_root = normalized_path(primary_root)
  target_root = vim.fs.normalize(target_root)

  for _, entry in ipairs(allowlist or {}) do
    local ok, err = M.validate_allowlist_entry(entry)
    if not ok then
      return nil, err
    end

    local source = vim.fs.joinpath(primary_root, entry)
    local target = vim.fs.joinpath(target_root, entry)
    local source_stat = vim.uv.fs_stat(source)

    if not source_stat then
      table.insert(result.skipped_missing, entry)
    elseif source_stat.type == "directory" then
      return nil, "allowlist entries must be repo-relative file paths"
    elseif not path_exists(target) then
      local ensured, ensure_err = ensure_parent_dir(target)
      if not ensured then
        return nil, ensure_err
      end

      local linked, link_err = vim.uv.fs_symlink(source, target)
      if not linked then
        return nil, link_err or ("failed to link " .. entry)
      end

      table.insert(result.linked, entry)
    elseif is_same_symlink(target, source) then
      table.insert(result.reused, entry)
    else
      return nil, "env allowlist conflict at " .. entry
    end
  end

  table.sort(result.linked)
  table.sort(result.reused)
  table.sort(result.skipped_missing)

  return result, nil
end

return M
