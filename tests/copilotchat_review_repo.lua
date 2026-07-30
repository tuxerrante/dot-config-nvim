local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
  end
end

local function assert_truthy(value, message)
  if not value then
    error(message or "expected truthy value")
  end
end

local function assert_match(text, needle, message)
  if type(text) ~= "string" or not string.find(text, needle, 1, true) then
    error((message or "expected match") .. "\nneedle: " .. needle .. "\ntext:\n" .. vim.inspect(text))
  end
end

local function assert_error_result(result, err, needle, message)
  if result ~= nil then
    error((message or "expected nil result") .. "\nactual result: " .. vim.inspect(result))
  end

  assert_match(err, needle, message)
end

local function assert_nil(value, message)
  if value ~= nil then
    error((message or "expected nil") .. "\nactual: " .. vim.inspect(value))
  end
end

local function run_cmd(cmd, cwd)
  local result = vim.system(cmd, {
    cwd = cwd,
    text = true,
  }):wait()

  if result.code ~= 0 then
    error(("command failed (%s)\nstdout:\n%s\nstderr:\n%s"):format(table.concat(cmd, " "), result.stdout or "", result.stderr or ""))
  end

  return vim.trim(result.stdout or "")
end

local function write_file(path, text)
  local fd = assert(vim.uv.fs_open(path, "w", 420))
  assert(vim.uv.fs_write(fd, text))
  assert(vim.uv.fs_close(fd))
end

local function make_git_commit(repo, relative_path, body, message)
  write_file(vim.fs.joinpath(repo, relative_path), body)
  run_cmd({ "git", "add", relative_path }, repo)
  run_cmd({ "git", "commit", "-m", message }, repo)
  return run_cmd({ "git", "rev-parse", "HEAD" }, repo)
end

local function assert_detached_head(repo)
  local ref = run_cmd({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, repo)
  assert_equal(ref, "HEAD", "worktree should remain detached")
end

local function test_repo_root()
  return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
end

local function with_temp_dir(prefix, fn)
  local parent = vim.fs.joinpath(test_repo_root(), ".tmp-test-fixtures")
  if not vim.uv.fs_stat(parent) then
    assert_truthy(vim.fn.mkdir(parent, "p") == 1, "failed to create fixture parent " .. parent)
  end
  local root = vim.fs.joinpath(parent, ("%s-%d"):format(prefix, vim.uv.hrtime()))
  assert_truthy(vim.fn.mkdir(root, "p") == 1, "failed to create temp dir " .. root)
  local ok, result = xpcall(function()
    return fn(root)
  end, debug.traceback)
  vim.fn.delete(root, "rf")
  if not ok then
    error(result)
  end
  return result
end

local function assert_no_error(err, message)
  if err ~= nil then
    error((message or "expected no error") .. "\nerr: " .. vim.inspect(err))
  end
end

local function assert_remote_owner_repo(result, root, owner_repo, message)
  assert_equal(result, {
    repo_root = root,
    owner_repo = owner_repo,
  }, message)
end

local function assert_raises(fn, needle, message)
  local ok, err = pcall(fn)
  if ok then
    error(message or ("expected error containing " .. needle))
  end
  assert_match(err, needle, message)
end

local function with_stub(tbl, key, value, fn)
  local original = tbl[key]
  tbl[key] = value
  local ok, result, extra = xpcall(fn, debug.traceback)
  tbl[key] = original
  if not ok then
    error(result)
  end
  return result, extra
end

local function await_result(invoke, timeout_ms)
  local result = nil
  local err = nil
  local done = false

  invoke(function(res, failure)
    result = res
    err = failure
    done = true
  end)

  assert_truthy(vim.wait(timeout_ms or 1000, function()
    return done
  end), "timed out waiting for async callback")

  return result, err
end

local function with_repo_env(opts, fn)
  opts = opts or {}

  local original_cwd = vim.uv.cwd
  local original_list_bufs = vim.api.nvim_list_bufs
  local original_buf_get_name = vim.api.nvim_buf_get_name
  local original_system = vim.system
  local original_select = vim.ui.select
  local original_input = vim.ui.input

  local buffers = opts.buffers or {}
  local responses = opts.responses or {}
  local calls = {}

  local function command_key(cmd)
    return table.concat(cmd, "\31")
  end

  vim.uv.cwd = function()
    return opts.cwd
  end

  vim.api.nvim_list_bufs = function()
    local items = {}
    for index = 1, #buffers do
      items[index] = index
    end
    return items
  end

  vim.api.nvim_buf_get_name = function(bufnr)
    return buffers[bufnr] or ""
  end

  vim.system = function(cmd, sysopts)
    table.insert(calls, {
      cmd = vim.deepcopy(cmd),
      cwd = sysopts and sysopts.cwd or nil,
      text = sysopts and sysopts.text or nil,
    })

    local response = responses[command_key(cmd)]
    if not response then
      error("unexpected vim.system call: " .. table.concat(cmd, " "))
    end

    if type(response) == "function" then
      response = response(sysopts, calls)
    end

    return {
      wait = function()
        return vim.tbl_extend("force", {
          code = 0,
          stdout = "",
          stderr = "",
        }, response or {})
      end,
    }
  end

  vim.ui.select = opts.select_fn or original_select
  vim.ui.input = opts.input_fn or original_input

  local ok, result, extra = xpcall(function()
    return fn(calls)
  end, debug.traceback)

  vim.uv.cwd = original_cwd
  vim.api.nvim_list_bufs = original_list_bufs
  vim.api.nvim_buf_get_name = original_buf_get_name
  vim.system = original_system
  vim.ui.select = original_select
  vim.ui.input = original_input

  if not ok then
    error(result)
  end

  return result, extra
end

local function test_parse_pr_url()
  package.loaded.copilotchat_review_repo = nil
  local review_repo = require("copilotchat_review_repo")

  local parsed, err = review_repo.parse_pr_url("https://github.com/owner-name/repo_name/pull/123/")
  assert_no_error(err, "valid PR URL should not return an error")
  assert_equal(parsed, {
    owner = "owner-name",
    repo = "repo_name",
    number = 123,
    owner_repo = "owner-name/repo_name",
    url = "https://github.com/owner-name/repo_name/pull/123",
  }, "parse_pr_url should normalize a GitHub PR URL")

  local invalid_result, invalid_err = review_repo.parse_pr_url("https://github.com/owner/repo/issues/123")
  assert_error_result(invalid_result, invalid_err, "GitHub pull request URL", "non-PR URL should be rejected with a clear error")

  local remote_result, remote_err = review_repo.parse_pr_url("git@github.com:owner/repo.git")
  assert_error_result(remote_result, remote_err, "GitHub pull request URL", "remote URL is not a PR URL")
end

local function test_normalize_github_remote()
  package.loaded.copilotchat_review_repo = nil
  local review_repo = require("copilotchat_review_repo")

  assert_equal(review_repo.normalize_github_remote("https://github.com/Owner/Repo.git"), "Owner/Repo", "https remote should normalize")
  assert_equal(review_repo.normalize_github_remote("git@github.com:Owner/Repo.git"), "Owner/Repo", "scp remote should normalize")
  assert_equal(review_repo.normalize_github_remote("ssh://git@github.com/Owner/Repo"), "Owner/Repo", "ssh remote should normalize")
  assert_equal(review_repo.normalize_github_remote("https://gitlab.com/Owner/Repo.git"), nil, "non-GitHub remote should be rejected")
end

local function test_select_repo_root_prefers_cwd()
  package.loaded.copilotchat_review_repo = nil
  local review_repo = require("copilotchat_review_repo")
  local pr = {
    owner = "Owner",
    repo = "Repo",
    owner_repo = "Owner/Repo",
    number = 42,
  }

  with_repo_env({
    cwd = "/tmp/current/subdir",
    buffers = {
      "/tmp/other/lib/file.lua",
    },
    responses = {
      ["git\31-C\31/tmp/current/subdir\31rev-parse\31--show-toplevel"] = {
        stdout = "/tmp/current\n",
      },
      ["git\31-C\31/tmp/current\31remote\31get-url\31origin"] = {
        stdout = "git@github.com:Owner/Repo.git\n",
      },
      ["git\31-C\31/tmp/other/lib\31rev-parse\31--show-toplevel"] = {
        stdout = "/tmp/other\n",
      },
      ["git\31-C\31/tmp/other\31remote\31get-url\31origin"] = {
        stdout = "git@github.com:Else/Repo.git\n",
      },
    },
  }, function(calls)
    local result, err = review_repo.select_repo_root(pr)
    assert_no_error(err, "matching cwd repo should not error")
    assert_remote_owner_repo(result, "/tmp/current", "Owner/Repo", "cwd repo should be selected first when it matches")
    assert_equal(#calls, 4, "select_repo_root should inspect remaining candidates before confirming there is no ambiguity")
  end)
end

local function test_select_repo_root_falls_back_to_buffers()
  package.loaded.copilotchat_review_repo = nil
  local review_repo = require("copilotchat_review_repo")
  local pr = {
    owner = "Owner",
    repo = "Repo",
    owner_repo = "Owner/Repo",
    number = 42,
  }

  with_repo_env({
    cwd = "/tmp/nomatch",
    buffers = {
      "/tmp/match/lua/file.lua",
      "/tmp/match/tests/spec.lua",
      "/tmp/other/README.md",
    },
    responses = {
      ["git\31-C\31/tmp/nomatch\31rev-parse\31--show-toplevel"] = {
        stdout = "/tmp/nomatch\n",
      },
      ["git\31-C\31/tmp/nomatch\31remote\31get-url\31origin"] = {
        stdout = "git@github.com:Else/Repo.git\n",
      },
      ["git\31-C\31/tmp/match/lua\31rev-parse\31--show-toplevel"] = {
        stdout = "/tmp/match\n",
      },
      ["git\31-C\31/tmp/match/tests\31rev-parse\31--show-toplevel"] = {
        stdout = "/tmp/match\n",
      },
      ["git\31-C\31/tmp/match\31remote\31get-url\31origin"] = {
        stdout = "https://github.com/Owner/Repo.git\n",
      },
      ["git\31-C\31/tmp/other\31rev-parse\31--show-toplevel"] = {
        stdout = "/tmp/other\n",
      },
      ["git\31-C\31/tmp/other\31remote\31get-url\31origin"] = {
        stdout = "https://github.com/Else/Repo.git\n",
      },
    },
  }, function()
    local result, err = review_repo.select_repo_root(pr)
    assert_no_error(err, "buffer fallback should not error")
    assert_remote_owner_repo(result, "/tmp/match", "Owner/Repo", "loaded buffers should be searched after cwd")
  end)
end

local function test_select_repo_root_errors_when_missing()
  package.loaded.copilotchat_review_repo = nil
  local review_repo = require("copilotchat_review_repo")
  local pr = {
    owner = "Owner",
    repo = "Repo",
    owner_repo = "Owner/Repo",
    number = 42,
  }

  with_repo_env({
    cwd = "/tmp/nomatch",
    buffers = {
      "/tmp/other/file.lua",
    },
    input_fn = function(_, on_choice)
      vim.schedule(function()
        on_choice("/tmp/manual/repo")
      end)
    end,
    responses = {
      ["git\31-C\31/tmp/nomatch\31rev-parse\31--show-toplevel"] = {
        stdout = "/tmp/nomatch\n",
      },
      ["git\31-C\31/tmp/nomatch\31remote\31get-url\31origin"] = {
        stdout = "https://github.com/Else/Repo.git\n",
      },
      ["git\31-C\31/tmp/other\31rev-parse\31--show-toplevel"] = {
        stdout = "/tmp/other\n",
      },
      ["git\31-C\31/tmp/other\31remote\31get-url\31origin"] = {
        stdout = "https://github.com/Else/Other.git\n",
      },
      ["git\31-C\31/tmp/manual/repo\31rev-parse\31--show-toplevel"] = {
        stdout = "/tmp/manual/repo\n",
      },
      ["git\31-C\31/tmp/manual/repo\31remote\31get-url\31origin"] = {
        stdout = "https://github.com/Owner/Repo.git\n",
      },
    },
  }, function()
    local result, err = await_result(function(on_done)
      review_repo.select_repo_root(pr, on_done)
    end)
    assert_no_error(err, "manual repo selection should not error")
    assert_remote_owner_repo(result, "/tmp/manual/repo", "Owner/Repo", "manual repo prompt should allow selecting a matching checkout")
  end)
end

local function test_select_repo_root_rejects_manual_repo_with_wrong_origin()
  package.loaded.copilotchat_review_repo = nil
  local review_repo = require("copilotchat_review_repo")
  local pr = {
    owner = "Owner",
    repo = "Repo",
    owner_repo = "Owner/Repo",
    number = 42,
  }

  with_repo_env({
    cwd = "/tmp/nomatch",
    buffers = {
      "/tmp/other/file.lua",
    },
    input_fn = function(_, on_choice)
      vim.schedule(function()
        on_choice("/tmp/manual/repo")
      end)
    end,
    responses = {
      ["git\31-C\31/tmp/nomatch\31rev-parse\31--show-toplevel"] = {
        stdout = "/tmp/nomatch\n",
      },
      ["git\31-C\31/tmp/nomatch\31remote\31get-url\31origin"] = {
        stdout = "https://github.com/Else/Repo.git\n",
      },
      ["git\31-C\31/tmp/other\31rev-parse\31--show-toplevel"] = {
        stdout = "/tmp/other\n",
      },
      ["git\31-C\31/tmp/other\31remote\31get-url\31origin"] = {
        stdout = "https://github.com/Else/Other.git\n",
      },
      ["git\31-C\31/tmp/manual/repo\31rev-parse\31--show-toplevel"] = {
        stdout = "/tmp/manual/repo\n",
      },
      ["git\31-C\31/tmp/manual/repo\31remote\31get-url\31origin"] = {
        stdout = "https://github.com/Else/Repo.git\n",
      },
    },
  }, function()
    local result, err = await_result(function(on_done)
      review_repo.select_repo_root(pr, on_done)
    end)
    assert_error_result(
      result,
      err,
      "does not match GitHub repo Owner/Repo",
      "manual repo selection should reject a checkout whose origin mismatches the PR repo"
    )
  end)
end

local function test_select_repo_root_prompts_on_ambiguous_match()
  package.loaded.copilotchat_review_repo = nil
  local review_repo = require("copilotchat_review_repo")
  local pr = {
    owner = "Owner",
    repo = "Repo",
    owner_repo = "Owner/Repo",
    number = 42,
  }

  with_repo_env({
    cwd = "/tmp/one",
    buffers = {
      "/tmp/two/lua/file.lua",
    },
    select_fn = function(items, _, on_choice)
      vim.schedule(function()
        on_choice(items[2])
      end)
    end,
    responses = {
      ["git\31-C\31/tmp/one\31rev-parse\31--show-toplevel"] = {
        stdout = "/tmp/one\n",
      },
      ["git\31-C\31/tmp/one\31remote\31get-url\31origin"] = {
        stdout = "git@github.com:Owner/Repo.git\n",
      },
      ["git\31-C\31/tmp/two/lua\31rev-parse\31--show-toplevel"] = {
        stdout = "/tmp/two\n",
      },
      ["git\31-C\31/tmp/two\31remote\31get-url\31origin"] = {
        stdout = "https://github.com/Owner/Repo.git\n",
      },
    },
  }, function()
    local original_wait = vim.wait
    local blocked_waits = 0
    vim.wait = function(...)
      blocked_waits = blocked_waits + 1
      return original_wait(...)
    end
    local result, err = await_result(function(on_done)
      review_repo.select_repo_root(pr, on_done)
    end)
    vim.wait = original_wait
    assert_no_error(err, "ambiguous repo matches should prompt instead of erroring")
    assert_remote_owner_repo(result, "/tmp/two", "Owner/Repo", "user-selected repo match should be returned")
    assert_equal(blocked_waits, 1, "only the test harness should wait; repo selection should stay callback-driven")
  end)
end

local function test_resolve_primary_checkout()
  package.loaded.copilotchat_review_repo = nil
  local review_repo = require("copilotchat_review_repo")

  with_repo_env({
    responses = {
      ["git\31-C\31/tmp/repo/.worktrees/pr-42\31worktree\31list\31--porcelain"] = {
        stdout = table.concat({
          "worktree /tmp/repo",
          "HEAD abcdef0",
          "branch refs/heads/main",
          "",
          "worktree /tmp/repo/.worktrees/pr-42",
          "HEAD 1234567",
          "detached",
          "",
        }, "\n"),
      },
    },
  }, function()
    local primary, err = review_repo.resolve_primary_checkout("/tmp/repo/.worktrees/pr-42")
    assert_no_error(err, "registered worktree should resolve a primary checkout")
    assert_equal(primary, "/tmp/repo", "first porcelain worktree entry should be treated as primary checkout")
  end)
end

local function test_ensure_pr_worktree_creates_detached_checkout()
  package.loaded.copilotchat_review_repo = nil
  local review_repo = require("copilotchat_review_repo")
  local pr = {
    owner = "Owner",
    repo = "Repo",
    owner_repo = "Owner/Repo",
    number = 42,
  }

  with_repo_env({
    responses = {
      ["git\31-C\31/tmp/repo/subdir\31worktree\31list\31--porcelain"] = {
        stdout = table.concat({
          "worktree /tmp/repo",
          "HEAD abcdef0",
          "branch refs/heads/main",
          "",
        }, "\n"),
      },
      ["git\31-C\31/tmp/repo\31fetch\31origin\31pull/42/head"] = {},
      ["git\31-C\31/tmp/repo\31rev-parse\31FETCH_HEAD"] = {
        stdout = "deadbeef\n",
      },
      ["git\31-C\31/tmp/repo\31worktree\31add\31--detach\31/tmp/repo/.worktrees/pr-42\31FETCH_HEAD"] = {},
    },
  }, function()
    local result, err = review_repo.ensure_pr_worktree(pr, "/tmp/repo/subdir")
    assert_no_error(err, "creating a PR worktree should not error")
    assert_equal(result, {
      repo_root = "/tmp/repo/subdir",
      primary_root = "/tmp/repo",
      worktree_root = "/tmp/repo/.worktrees/pr-42",
      owner_repo = "Owner/Repo",
      pr = pr,
    }, "new PR worktree should use deterministic path under primary checkout")
  end)
end

local function test_ensure_pr_worktree_updates_clean_registered_checkout()
  package.loaded.copilotchat_review_repo = nil
  local review_repo = require("copilotchat_review_repo")
  local pr = {
    owner = "Owner",
    repo = "Repo",
    owner_repo = "Owner/Repo",
    number = 42,
  }

  with_repo_env({
    responses = {
      ["git\31-C\31/tmp/repo/.worktrees/pr-42\31worktree\31list\31--porcelain"] = {
        stdout = table.concat({
          "worktree /tmp/repo",
          "HEAD abcdef0",
          "branch refs/heads/main",
          "",
          "worktree /tmp/repo/.worktrees/pr-42",
          "HEAD cafebabe",
          "detached",
          "",
        }, "\n"),
      },
      ["git\31-C\31/tmp/repo\31fetch\31origin\31pull/42/head"] = {},
      ["git\31-C\31/tmp/repo\31rev-parse\31FETCH_HEAD"] = {
        stdout = "deadbeef\n",
      },
      ["git\31-C\31/tmp/repo/.worktrees/pr-42\31status\31--porcelain"] = {
        stdout = "",
      },
      ["git\31-C\31/tmp/repo/.worktrees/pr-42\31rev-parse\31HEAD"] = {
        stdout = "cafebabe\n",
      },
      ["git\31-C\31/tmp/repo/.worktrees/pr-42\31checkout\31--detach\31deadbeef"] = {},
    },
  }, function()
    local result, err = review_repo.ensure_pr_worktree(pr, "/tmp/repo/.worktrees/pr-42")
    assert_no_error(err, "reusing a clean registered PR worktree should not error")
    assert_equal(result, {
      repo_root = "/tmp/repo/.worktrees/pr-42",
      primary_root = "/tmp/repo",
      worktree_root = "/tmp/repo/.worktrees/pr-42",
      owner_repo = "Owner/Repo",
      pr = pr,
    }, "existing clean PR worktree should be reused")
  end)
end

local function test_ensure_pr_worktree_prompts_on_dirty_checkout()
  package.loaded.copilotchat_review_repo = nil
  local review_repo = require("copilotchat_review_repo")
  local pr = {
    owner = "Owner",
    repo = "Repo",
    owner_repo = "Owner/Repo",
    number = 42,
  }

  with_repo_env({
    select_fn = function(items, _, on_choice)
      vim.schedule(function()
        on_choice(items[1])
      end)
    end,
    responses = {
      ["git\31-C\31/tmp/repo/.worktrees/pr-42\31worktree\31list\31--porcelain"] = {
        stdout = table.concat({
          "worktree /tmp/repo",
          "HEAD abcdef0",
          "branch refs/heads/main",
          "",
          "worktree /tmp/repo/.worktrees/pr-42",
          "HEAD cafebabe",
          "detached",
          "",
        }, "\n"),
      },
      ["git\31-C\31/tmp/repo\31fetch\31origin\31pull/42/head"] = {},
      ["git\31-C\31/tmp/repo\31rev-parse\31FETCH_HEAD"] = {
        stdout = "deadbeef\n",
      },
      ["git\31-C\31/tmp/repo/.worktrees/pr-42\31status\31--porcelain"] = {
        stdout = " M lua/file.lua\n",
      },
    },
  }, function()
    local original_wait = vim.wait
    local blocked_waits = 0
    vim.wait = function(...)
      blocked_waits = blocked_waits + 1
      return original_wait(...)
    end
    local result, err = await_result(function(on_done)
      review_repo.ensure_pr_worktree(pr, "/tmp/repo/.worktrees/pr-42", on_done)
    end)
    vim.wait = original_wait
    assert_no_error(err, "dirty worktree should prompt instead of failing immediately")
    assert_equal(result, {
      repo_root = "/tmp/repo/.worktrees/pr-42",
      primary_root = "/tmp/repo",
      worktree_root = "/tmp/repo/.worktrees/pr-42",
      owner_repo = "Owner/Repo",
      pr = pr,
    }, "dirty worktree reuse should return the existing worktree when explicitly selected")
    assert_equal(blocked_waits, 1, "only the test harness should wait; dirty worktree reuse should stay callback-driven")
  end)
end

local function test_ensure_pr_worktree_rejects_unregistered_path_on_disk()
  package.loaded.copilotchat_review_repo = nil
  local review_repo = require("copilotchat_review_repo")
  local pr = {
    owner = "Owner",
    repo = "Repo",
    owner_repo = "Owner/Repo",
    number = 42,
  }

  local primary = vim.fn.tempname()
  assert_truthy(vim.fn.mkdir(primary .. "/.worktrees/pr-42", "p") == 1, "failed to create stray worktree path")

  with_repo_env({
    responses = {
      ["git\31-C\31" .. primary .. "\31worktree\31list\31--porcelain"] = {
        stdout = table.concat({
          "worktree " .. primary,
          "HEAD abcdef0",
          "branch refs/heads/main",
          "",
        }, "\n"),
      },
      ["git\31-C\31" .. primary .. "\31fetch\31origin\31pull/42/head"] = {},
      ["git\31-C\31" .. primary .. "\31rev-parse\31FETCH_HEAD"] = {
        stdout = "deadbeef\n",
      },
    },
  }, function()
    local result, err = review_repo.ensure_pr_worktree(pr, primary)
    assert_error_result(result, err, "exists on disk but is not a registered git worktree", "stray path should be a hard error")
  end)
end

local function test_real_git_pr_worktree_is_created_and_reused()
  package.loaded.copilotchat_review_repo = nil
  local review_repo = require("copilotchat_review_repo")

  with_temp_dir("copilot-pr-worktree", function(root)
    local origin = vim.fs.joinpath(root, "origin.git")
    local primary = vim.fs.joinpath(root, "primary")
    local author = vim.fs.joinpath(root, "author")

    run_cmd({ "git", "init", "--bare", origin })
    run_cmd({ "git", "clone", origin, primary })
    run_cmd({ "git", "clone", origin, author })

    run_cmd({ "git", "config", "user.name", "Test User" }, primary)
    run_cmd({ "git", "config", "user.email", "test@example.com" }, primary)
    run_cmd({ "git", "config", "user.name", "Test User" }, author)
    run_cmd({ "git", "config", "user.email", "test@example.com" }, author)
    run_cmd({ "git", "remote", "set-url", "origin", origin }, author)

    make_git_commit(primary, "README.md", "base\n", "base commit")
    run_cmd({ "git", "branch", "-M", "main" }, primary)
    run_cmd({ "git", "push", "origin", "main" }, primary)

    run_cmd({ "git", "fetch", "origin", "main" }, author)
    run_cmd({ "git", "checkout", "-B", "main", "origin/main" }, author)

    local first_head = make_git_commit(author, "feature.txt", "first revision\n", "first pr revision")
    run_cmd({ "git", "push", "origin", ("HEAD:refs/pull/%d/head"):format(42) }, author)

    local pr = {
      owner = "Owner",
      repo = "Repo",
      owner_repo = "Owner/Repo",
      number = 42,
    }

    local first_result, first_err = review_repo.ensure_pr_worktree(pr, primary)
    assert_no_error(first_err, "first PR worktree creation should succeed")
    assert_equal(first_result, {
      repo_root = primary,
      primary_root = primary,
      worktree_root = vim.fs.joinpath(primary, ".worktrees", "pr-42"),
      owner_repo = "Owner/Repo",
      pr = pr,
    }, "first ensure_pr_worktree call should return the created worktree details")

    local worktree_root = first_result.worktree_root
    assert_truthy(vim.uv.fs_stat(worktree_root) ~= nil, "PR worktree should exist on disk after creation")
    assert_detached_head(worktree_root)
    assert_equal(run_cmd({ "git", "rev-parse", "HEAD" }, worktree_root), first_head, "new PR worktree should point at fetched pull head")

    local second_head = make_git_commit(author, "feature.txt", "second revision\n", "second pr revision")
    run_cmd({ "git", "push", "--force", "origin", ("HEAD:refs/pull/%d/head"):format(42) }, author)

    local second_result, second_err = review_repo.ensure_pr_worktree(pr, primary)
    assert_no_error(second_err, "existing PR worktree update should succeed")
    assert_equal(second_result, first_result, "second ensure_pr_worktree call should reuse the same deterministic worktree path")
    assert_detached_head(worktree_root)
    assert_equal(run_cmd({ "git", "rev-parse", "HEAD" }, worktree_root), second_head, "existing PR worktree should update to the latest fetched pull head")
    assert_equal(run_cmd({ "git", "status", "--porcelain" }, worktree_root), "", "updated PR worktree should remain clean")
  end)
end

function M.run()
  test_parse_pr_url()
  test_normalize_github_remote()
  test_select_repo_root_prefers_cwd()
  test_select_repo_root_falls_back_to_buffers()
  test_select_repo_root_errors_when_missing()
  test_select_repo_root_rejects_manual_repo_with_wrong_origin()
  test_select_repo_root_prompts_on_ambiguous_match()
  test_resolve_primary_checkout()
  test_ensure_pr_worktree_creates_detached_checkout()
  test_ensure_pr_worktree_updates_clean_registered_checkout()
  test_ensure_pr_worktree_prompts_on_dirty_checkout()
  test_ensure_pr_worktree_rejects_unregistered_path_on_disk()
  test_real_git_pr_worktree_is_created_and_reused()
  print("PASS copilotchat_review_repo")
end

return M
