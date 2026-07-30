local M = {}

local function normalized_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

local function path_join(...)
  return vim.fs.normalize(vim.fs.joinpath(...))
end

local function is_under_root(path, root)
  if not path or not root then
    return false
  end

  return path == root or path:sub(1, #root + 1) == (root .. "/")
end

local function relative_to_root(path, root)
  if path == root then
    return "."
  end

  return path:sub(#root + 2)
end

local function collect_repo_file_buffers(source_root)
  local affected = {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    local buftype = vim.bo[bufnr].buftype
    if name ~= "" and buftype == "" then
      local normalized = normalized_path(name)
      if is_under_root(normalized, source_root) then
        table.insert(affected, {
          bufnr = bufnr,
          path = normalized,
          relpath = relative_to_root(normalized, source_root),
          modified = vim.bo[bufnr].modified,
        })
      end
    end
  end

  return affected
end

local function complete(callback, result, err)
  if callback then
    callback(result, err)
    return nil, nil
  end

  return result, err
end

local function prompt_dirty_buffers(_dirty, callback)
  if not callback then
    return nil, "dirty buffer switch requires an async callback"
  end

  vim.ui.select({ "save-and-switch", "cancel" }, {
    prompt = "Repo-local modified buffers detected",
  }, function(item)
    local choice = item or "cancel"
    if choice ~= "save-and-switch" then
      callback(nil, "switch cancelled")
      return
    end

    callback(choice, nil)
  end)

  return nil, nil
end

local function save_buffers(dirty)
  for _, item in ipairs(dirty) do
    local ok, err = pcall(vim.api.nvim_buf_call, item.bufnr, function()
      vim.cmd("silent write")
    end)
    if not ok then
      return nil, tostring(err)
    end
  end

  return true, nil
end

local function remap_buffers(affected, _source_root, target_root)
  local switched_paths = {}
  local skipped_paths = {}

  for _, item in ipairs(affected) do
    local target_path = path_join(target_root, item.relpath)
    if vim.uv.fs_stat(target_path) then
      vim.api.nvim_buf_set_name(item.bufnr, target_path)
      vim.api.nvim_buf_call(item.bufnr, function()
        vim.cmd("silent edit!")
      end)
      table.insert(switched_paths, item.relpath)
    else
      table.insert(skipped_paths, item.relpath)
    end
  end

  table.sort(switched_paths)
  table.sort(skipped_paths)

  return switched_paths, skipped_paths
end

local function finish_switch(affected, source_root, target_root, callback)
  local switched_paths, skipped_paths = remap_buffers(affected, source_root, target_root)
  vim.cmd("cd " .. vim.fn.fnameescape(target_root))

  return complete(callback, {
    switched_paths = switched_paths,
    skipped_paths = skipped_paths,
  }, nil)
end

function M.execute(source_root, target_root, callback)
  source_root = normalized_path(source_root)
  target_root = normalized_path(target_root)

  if not source_root or not target_root then
    return nil, "source_root and target_root are required"
  end

  local affected = collect_repo_file_buffers(source_root)
  local dirty = vim.tbl_filter(function(item)
    return item.modified
  end, affected)

  if #dirty > 0 then
    if not callback then
      return nil, "dirty buffer switch requires an async callback"
    end

    return prompt_dirty_buffers(dirty, function(_, prompt_err)
      if prompt_err then
        callback(nil, prompt_err)
        return
      end

      local ok, err = save_buffers(dirty)
      if not ok then
        callback(nil, err)
        return
      end

      finish_switch(affected, source_root, target_root, callback)
    end)
  end

  return finish_switch(affected, source_root, target_root, callback)
end

return M
