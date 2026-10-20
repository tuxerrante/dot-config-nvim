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

local function assert_nil(value, message)
  if value ~= nil then
    error((message or "expected nil") .. "\nactual: " .. vim.inspect(value))
  end
end

local function assert_match(text, needle, message)
  if type(text) ~= "string" or not string.find(text, needle, 1, true) then
    error((message or "expected match") .. "\nneedle: " .. needle .. "\ntext:\n" .. vim.inspect(text))
  end
end

local function assert_not_match(text, needle, message)
  if type(text) == "string" and string.find(text, needle, 1, true) then
    error((message or "unexpected match") .. "\nneedle: " .. needle .. "\ntext:\n" .. text)
  end
end

local function write_file(path, text)
  local parent = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(parent, "p")
  local fd = assert(vim.uv.fs_open(path, "w", 420))
  assert(vim.uv.fs_write(fd, text, 0))
  assert(vim.uv.fs_close(fd))
end

local function with_temp_dir(prefix, fn)
  local parent = vim.fs.joinpath(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"), ".tmp-test-fixtures")
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

local function allow_github_auth(review_prep)
  review_prep.ensure_github_auth = function(callback)
    callback(nil)
  end
end

local function clear_review_prep_modules()
  package.loaded.review_prep = nil
  package.loaded.review_repo = nil
  package.loaded.review_switch = nil
  package.loaded.review_env = nil
  package.loaded["claudecode.terminal"] = nil
end

local function default_helper_stubs()
  return {
    repo = {
      parse_pr_url = function(pr_url)
        return {
          owner = "Owner",
          repo = "Repo",
          number = 123,
          owner_repo = "Owner/Repo",
          url = pr_url,
        }, nil
      end,
      select_repo_root = function(_pr)
        return {
          repo_root = "/host/repo",
          owner_repo = "Owner/Repo",
        }, nil
      end,
      ensure_pr_worktree = function(pr, repo_root)
        return {
          repo_root = repo_root,
          primary_root = "/primary/repo",
          worktree_root = "/primary/repo/.worktrees/pr-123",
          owner_repo = "Owner/Repo",
          pr = pr,
        }, nil
      end,
    },
    switch = {
      execute = function(_source_root, _target_root)
        return {
          switched_paths = {},
          skipped_paths = {},
        }, nil
      end,
    },
    env = {
      bootstrap = function(_primary_root, _target_root, _allowlist)
        return {
          linked = {},
          reused = {},
          skipped_missing = {},
        }, nil
      end,
    },
  }
end

local function with_review_prep(stubs, fn)
  clear_review_prep_modules()
  local saved_preload = {
    prep = package.preload.review_prep,
    repo = package.preload.review_repo,
    switch = package.preload.review_switch,
    env = package.preload.review_env,
    terminal = package.preload["claudecode.terminal"],
  }

  local helpers = default_helper_stubs()
  -- Fake claudecode.terminal: `active` is whether a Claude Code session is
  -- already running; `sent` records every paste.
  helpers.claude = {
    active = true,
    available = true,
    opened = 0,
    sent = {},
    send_ok = true,
    open_opts = {},
    buf = vim.api.nvim_create_buf(false, true),
  }
  if stubs then
    if stubs.repo then
      helpers.repo = stubs.repo
    end
    if stubs.switch then
      helpers.switch = stubs.switch
    end
    if stubs.env then
      helpers.env = stubs.env
    end
  end

  package.preload.review_repo = function()
    return helpers.repo
  end
  package.preload.review_switch = function()
    return helpers.switch
  end
  package.preload.review_env = function()
    return helpers.env
  end
  package.preload["claudecode.terminal"] = function()
    if not helpers.claude.available then
      error("module 'claudecode.terminal' not found")
    end
    return {
      get_active_terminal_bufnr = function()
        local c = helpers.claude
        if c.active and c.buf and vim.api.nvim_buf_is_valid(c.buf) then
          return c.buf
        end
        return nil
      end,
      open = function(open_opts)
        helpers.claude.opened = helpers.claude.opened + 1
        table.insert(helpers.claude.open_opts, open_opts)
        if helpers.claude.open_throws then
          error("Process failed to start: operation not permitted")
        end
        helpers.claude.active = not helpers.claude.never_starts
        if helpers.claude.active then
          helpers.claude.buf = vim.api.nvim_create_buf(false, true)
        end
      end,
      send_to_terminal = function(text, opts)
        table.insert(helpers.claude.sent, { text = text, opts = opts })
        return helpers.claude.send_ok
      end,
    }
  end

  local ok, result = xpcall(function()
    local review_prep = require("review_prep")
    return fn(review_prep, helpers)
  end, debug.traceback)

  package.preload.review_prep = saved_preload.prep
  package.preload.review_repo = saved_preload.repo
  package.preload.review_switch = saved_preload.switch
  package.preload.review_env = saved_preload.env
  package.preload["claudecode.terminal"] = saved_preload.terminal
  clear_review_prep_modules()

  if not ok then
    error(result)
  end

  return result
end

local function test_build_prompt()
  with_review_prep(nil, function(review_prep)
    local prompt = review_prep.build_prompt({
      pr = {
        url = "https://github.com/Azure/ARO-RP/pull/5009",
        owner_repo = "Azure/ARO-RP",
        number = 5009,
        title = "Add CRG, Capacity Reservation and VM Client wrappers",
        author = "rh-returners",
        base_ref = "master",
        head_ref = "ARO-28673/capacity-reservation-client-wrappers",
        merge_state = "BLOCKED",
        review_decision = "REVIEW_REQUIRED",
        files = {
          "pkg/util/azureclient/azuresdk/armcompute/capacityreservationgroups.go",
          "pkg/util/azureclient/azuresdk/armcompute/capacityreservationgroups_addons.go",
        },
      },
      repo = {
        root = "/tmp/ARO-RP",
        branch = "master",
      },
      rules_and_docs = {
        {
          provenance = "repo-doc",
          path = "CLAUDE.md",
          excerpt = "Use Makefile targets first.\nReview for missing tests.",
        },
      },
      domain_context = {
        {
          provenance = "domain-doc",
          path = "docs/agent-guides/multi-module-build.md",
          excerpt = "make test-go may mutate generated files.",
        },
      },
      pr_diff = {
        stat = "pkg/util/azureclient/foo.go | 2 +-\n1 file changed, 1 insertion(+), 1 deletion(-)",
        excerpt = table.concat({
          "diff --git a/pkg/util/azureclient/foo.go b/pkg/util/azureclient/foo.go",
          "@@ -1,3 +1,3 @@",
          "-old line",
          "+new line",
        }, "\n"),
      },
      quality_gates = {
        {
          command = "make test-go",
          source = "Makefile",
          note = "full Go validation pipeline",
        },
      },
      related_prs = {
        {
          number = 4999,
          title = "Prior capacity reservation prep",
          url = "https://github.com/Azure/ARO-RP/pull/4999",
          reason = "ARO-28673",
        },
      },
      jira = {
        {
          key = "ARO-28673",
          url = "https://redhat.atlassian.net/browse/ARO-28673",
          summary = "Add capacity reservation client wrappers",
          status = "In Progress",
          epic = {
            key = "ARO-24543",
            url = "https://redhat.atlassian.net/browse/ARO-24543",
            summary = "Control plane resize support",
            status = "In Progress",
            issue_type = "Epic",
          },
          linked_issues = {
            {
              key = "ARO-28674",
              url = "https://redhat.atlassian.net/browse/ARO-28674",
              summary = "Implement CRG provisioning for resize",
              status = "New",
              relation = "is depended on by",
            },
          },
        },
      },
      pr_conversations = {
        source = "github-pr-discussion",
        fetched_via = "graphql+issuecomment",
        unresolved_count = 1,
        resolved_count = 1,
        unresolved = {
          {
            label = "pkg/util/azureclient/foo.go:14",
            summary = "Reviewer still wants a nil guard before dereferencing the SDK result.",
          },
        },
        resolved = {
          {
            label = "tests/test_pr_review_prep.py:210",
            summary = "Earlier request for a stale-cache test was already addressed.",
          },
        },
        top_level_count = 1,
        top_level = {
          {
            author = "reviewer-six",
            summary = "Earlier top-level PR discussion explained why prior general comments still matter for this prompt.",
          },
        },
      },
      caveats = {
        "Jira refs discovered but not enriched.",
      },
    })

    assert_match(prompt, "Review GitHub PR https://github.com/Azure/ARO-RP/pull/5009", "prompt should include PR URL")
    assert_match(prompt, "PR diff summary", "prompt should include a diff summary section")
    assert_match(prompt, "pkg/util/azureclient/foo.go | 2 +-", "prompt should include diff stats")
    assert_not_match(prompt, "```diff", "prompt should not render a raw diff code fence")
    assert_not_match(prompt, "+new line", "prompt should not inline raw diff excerpt content")
    assert_match(
      prompt,
      "Use the checked-out local worktree and live repo tools for exact hunks; this prep stays at file-level summary only.",
      "prompt should point reviewers to the local worktree for detailed diff inspection"
    )
    assert_match(
      prompt,
      "Prior review discussion",
      "prompt should include the prior review discussion section"
    )
    assert_match(
      prompt,
      "Inline review threads are prioritized here, with a small set of high-signal top-level PR issue comments added as secondary context; standalone review bodies and the rest of the PR conversation are still excluded.",
      "prompt should describe the remaining PR conversation limitation precisely"
    )
    assert_match(
      prompt,
      "Top-level PR comments worth keeping in mind:",
      "prompt should render the secondary top-level PR discussion heading"
    )
    assert_match(
      prompt,
      "reviewer-six [top-level]: Earlier top-level PR discussion explained why prior general comments still matter for this prompt.",
      "prompt should summarize selected top-level PR comments without dumping raw formatting"
    )
    assert_match(prompt, "Rules and important docs", "prompt should include rules section")
    assert_match(prompt, "`make test-go` (Makefile)", "prompt should include quality gates")
    assert_match(prompt, "Epic [ARO-24543]", "prompt should include epic context")
    assert_match(prompt, "Linked: is depended on by: [ARO-28674]", "prompt should include linked Jira issues")
    assert_match(prompt, "Degraded-mode caveats", "prompt should include caveats section")
    assert_not_match(prompt, "Press <C-j> to send", "prompt should not include UI notification text")
  end)
end

local function test_build_prompt_caps_review_discussion_and_marks_cached_snapshot_stale()
  with_review_prep(nil, function(review_prep)
    local prompt = review_prep.build_prompt({
      cache_hit = true,
      pr = {
        url = "https://github.com/Owner/Repo/pull/123",
        title = "Example",
        files = {},
      },
      pr_conversations = {
        source = "github-pr-discussion",
        fetched_via = "graphql+issuecomment",
        unresolved_count = 5,
        resolved_count = 3,
        unresolved = {
          { label = "lua/a.lua:10", summary = "Unresolved thread one." },
          { label = "lua/b.lua:20", summary = "Unresolved thread two." },
          { label = "lua/c.lua:30", summary = "Unresolved thread three." },
          { label = "lua/d.lua:40", summary = "Unresolved thread four." },
          { label = "lua/e.lua:50", summary = "Unresolved thread five." },
        },
        resolved = {
          { label = "tests/a.lua:60", summary = "Resolved thread one." },
          { label = "tests/b.lua:70", summary = "Resolved thread two." },
          { label = "tests/c.lua:80", summary = "Resolved thread three." },
        },
        top_level_count = 3,
        top_level = {
          { author = "reviewer-a", summary = "Top-level PR comment one." },
          { author = "reviewer-b", summary = "Top-level PR comment two." },
          { author = "reviewer-c", summary = "Top-level PR comment three." },
        },
      },
      caveats = {},
    })

    assert_match(prompt, "Prior review discussion", "prompt should render the prior review discussion section")
    assert_match(prompt, "lua/a.lua:10", "prompt should include the first unresolved thread")
    assert_match(prompt, "lua/d.lua:40", "prompt should include the fourth unresolved thread")
    assert_not_match(prompt, "lua/e.lua:50", "prompt should cap unresolved thread rendering")
    assert_match(prompt, "... plus 1 more unresolved thread(s)", "prompt should summarize omitted unresolved threads")
    assert_match(prompt, "tests/a.lua:60", "prompt should include the first resolved thread")
    assert_match(prompt, "tests/b.lua:70", "prompt should include the second resolved thread")
    assert_not_match(prompt, "tests/c.lua:80", "prompt should cap resolved thread rendering")
    assert_match(prompt, "... plus 1 more resolved thread(s)", "prompt should summarize omitted resolved threads")
    assert_match(prompt, "reviewer-a [top-level]: Top-level PR comment one.", "prompt should include the first top-level PR comment")
    assert_match(prompt, "reviewer-b [top-level]: Top-level PR comment two.", "prompt should include the second top-level PR comment")
    assert_not_match(prompt, "reviewer-c [top-level]: Top-level PR comment three.", "prompt should cap top-level PR comment rendering")
    assert_match(
      prompt,
      "... plus 1 more high-signal top-level PR comment(s)",
      "prompt should summarize omitted top-level PR comments"
    )
    assert_match(
      prompt,
      "Review discussion snapshot may be stale because this bundle came from cache. Use `:PrepReview!` to refresh.",
      "prompt should call out cached conversation snapshots explicitly"
    )
  end)
end

local function test_collect_preserves_collector_contract_with_explicit_worktree_root()
  with_review_prep(nil, function(review_prep)
    local system_call = nil
    local received_bundle = nil
    local received_err = nil

    with_stub(vim, "system", function(argv, sysopts, callback)
      system_call = {
        argv = vim.deepcopy(argv),
        sysopts = vim.deepcopy(sysopts),
      }
      callback({
        code = 0,
        stdout = vim.json.encode({
          pr = {
            url = "https://github.com/Owner/Repo/pull/123",
            title = "Example",
            number = 123,
            files = {},
          },
          repo = {
            root = "/primary/repo/.worktrees/pr-123",
          },
        }),
        stderr = "",
      })

      return {}
    end, function()
      review_prep.collect("https://github.com/Owner/Repo/pull/123", {
        repo_root = "/primary/repo/.worktrees/pr-123",
        refresh = true,
      }, function(bundle, err)
        received_bundle = bundle
        received_err = err
      end)

      local completed = vim.wait(1000, function()
        return received_bundle ~= nil or received_err ~= nil
      end)
      assert_truthy(completed, "collect callback should complete")
    end)

    assert_equal(system_call, {
      argv = {
        "python3",
        vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/scripts/pr_review_prep.py",
        "https://github.com/Owner/Repo/pull/123",
        "--cache-dir",
        vim.fn.stdpath("cache") .. "/pr-review-prep",
        "--repo-root",
        "/primary/repo/.worktrees/pr-123",
        "--refresh",
      },
      sysopts = {
        cwd = "/primary/repo/.worktrees/pr-123",
        text = true,
      },
    }, "collect should keep the collector argv contract and launch from the selected worktree root")
    assert_nil(received_err, "collector success should not surface an error")
    assert_equal(received_bundle.repo.root, "/primary/repo/.worktrees/pr-123", "collector JSON should decode successfully")
  end)
end

local function test_build_prompt_tolerates_null_pr_diff()
  with_review_prep(nil, function(review_prep)
    local prompt = review_prep.build_prompt({
      pr = {
        url = "https://github.com/Owner/Repo/pull/123",
        title = "Example",
        files = {},
      },
      pr_diff = vim.NIL,
      caveats = {},
    })

    assert_match(prompt, "Review GitHub PR https://github.com/Owner/Repo/pull/123", "prompt should still render with null diff")
    assert_not_match(prompt, "PR diff", "null diff should not render an empty section")
  end)
end

local function test_build_prompt_tolerates_json_null_pr_metadata()
  with_review_prep(nil, function(review_prep)
    local bundle = vim.json.decode([[{
      "pr": {
        "url": "https://github.com/Owner/Repo/pull/123",
        "title": null,
        "owner_repo": "Owner/Repo",
        "number": 123,
        "author": null,
        "base_ref": null,
        "head_ref": null,
        "merge_state": null,
        "review_decision": null,
        "files": []
      },
      "repo": {
        "root": "/tmp/repo",
        "has_git": true,
        "branch": null
      },
      "caveats": []
    }]])
    local prompt = review_prep.build_prompt(bundle)

    assert_match(prompt, "Review GitHub PR https://github.com/Owner/Repo/pull/123: PR #123", "null title should fall back")
    assert_match(prompt, "base/head: `unknown` <- `unknown`", "null refs should fall back")
    assert_match(prompt, "author: `unknown`", "null author should fall back")
    assert_match(prompt, "merge state: `unknown`", "null merge state should fall back")
    assert_match(prompt, "review decision: `unknown`", "null review decision should fall back")
    assert_match(prompt, "local branch: `detached HEAD`", "null branch in a Git checkout should identify detached HEAD")
    assert_not_match(prompt, "vim.NIL", "JSON nulls must not leak into the prompt")
  end)
end

local function test_build_prompt_tolerates_json_null_jira_fields()
  with_review_prep(nil, function(review_prep)
    local bundle = vim.json.decode([[{
      "pr": {
        "url": "https://github.com/Owner/Repo/pull/123",
        "title": "Example",
        "files": []
      },
      "jira": [
        {
          "key": "ARO-1",
          "url": "https://jira.example/browse/ARO-1",
          "summary": null,
          "status": null,
          "epic": null,
          "parent": {
            "key": "ARO-0",
            "summary": null,
            "status": null,
            "issue_type": "Parent"
          },
          "linked_issues": [
            {
              "key": "ARO-2",
              "summary": null,
              "status": null,
              "relation": "relates to"
            }
          ]
        }
      ],
      "caveats": []
    }]])
    local prompt = review_prep.build_prompt(bundle)

    assert_match(prompt, "Jira refs", "prompt should still render the Jira section when decoded nulls are present")
    assert_match(
      prompt,
      "[ARO-1](https://jira.example/browse/ARO-1): summary unavailable",
      "null Jira summaries should degrade instead of crashing"
    )
    assert_match(prompt, "Parent ARO-0 [unknown]: summary unavailable", "null parent summaries should degrade instead of crashing")
    assert_match(prompt, "Linked: relates to: ARO-2 [unknown] summary unavailable", "null linked issue summaries should degrade instead of crashing")
  end)
end

local function test_ensure_github_auth_requires_authenticated_gh()
  with_review_prep(nil, function(review_prep)
    local system_call = nil
    local received_err = nil

    with_stub(vim, "system", function(argv, _, callback)
      system_call = vim.deepcopy(argv)
      callback({
        code = 1,
        stdout = "",
        stderr = "token invalid",
      })
      return {}
    end, function()
      review_prep.ensure_github_auth(function(err)
        received_err = err
      end)

      assert_truthy(vim.wait(1000, function()
        return received_err ~= nil
      end), "authentication check should complete")
    end)

    assert_equal(system_call, { "gh", "auth", "status", "-h", "github.com" }, "authentication check should use gh auth status")
    assert_equal(
      received_err,
      "GitHub authentication is required: run `gh auth login -h github.com`, then retry.",
      "invalid gh authentication should stop review preparation clearly"
    )
  end)
end

local function test_run_stops_before_worktree_prep_when_github_auth_fails()
  local selected_repo = false

  with_review_prep({
    repo = {
      select_repo_root = function()
        selected_repo = true
        return nil, "should not run"
      end,
    },
  }, function(review_prep)
    review_prep.ensure_github_auth = function(callback)
      callback("GitHub authentication is required.")
    end

    local notify_calls = {}
    with_stub(vim, "notify", function(message, level)
      table.insert(notify_calls, { message = message, level = level })
    end, function()
      review_prep.run("https://github.com/Owner/Repo/pull/123", {})
    end)

    assert_equal(selected_repo, false, "worktree preparation must not start without GitHub authentication")
    assert_equal(notify_calls[1].message, "GitHub authentication is required.", "authentication failure should be surfaced")
    assert_equal(notify_calls[1].level, vim.log.levels.ERROR, "authentication failure should be an error")
  end)
end

local function test_collect_runs_collector_from_selected_worktree_root()
  with_review_prep(nil, function(review_prep)
    with_temp_dir("review-collector", function(root)
      local source_root = vim.fs.joinpath(root, "source")
      local target_root = vim.fs.joinpath(root, "target", ".worktrees", "pr-123")
      local collector = vim.fs.joinpath(root, "collector.py")
      local cache_dir = vim.fs.joinpath(root, "cache")
      vim.fn.mkdir(source_root, "p")
      vim.fn.mkdir(target_root, "p")
      write_file(collector, table.concat({
        "#!/usr/bin/env python3",
        "import json",
        "import os",
        "import sys",
        "",
        "repo_root = None",
        "for index, arg in enumerate(sys.argv):",
        "    if arg == '--repo-root' and index + 1 < len(sys.argv):",
        "        repo_root = sys.argv[index + 1]",
        "",
        "print(json.dumps({",
        "    'pr': {",
        "        'url': sys.argv[1],",
        "        'title': 'Example',",
        "        'number': 123,",
        "        'files': [],",
        "    },",
        "    'repo': {",
        "        'root': repo_root,",
        "        'cwd': os.getcwd(),",
        "    },",
        "    'caveats': [],",
        "}))",
      }, "\n"))

      local original_collector = vim.g.pr_review_prep_collector
      local original_cache_dir = vim.g.pr_review_prep_cache_dir
      local original_cwd = vim.uv.cwd()
      vim.g.pr_review_prep_collector = collector
      vim.g.pr_review_prep_cache_dir = cache_dir
      vim.cmd("cd " .. vim.fn.fnameescape(source_root))

      local received_bundle = nil
      local received_err = nil
      review_prep.collect("https://github.com/Owner/Repo/pull/123", {
        repo_root = target_root,
        refresh = true,
      }, function(bundle, err)
        received_bundle = bundle
        received_err = err
      end)

      local completed = vim.wait(2000, function()
        return received_bundle ~= nil or received_err ~= nil
      end)

      vim.g.pr_review_prep_collector = original_collector
      vim.g.pr_review_prep_cache_dir = original_cache_dir
      vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))

      assert_truthy(completed, "collect callback should complete with the fake collector")
      assert_nil(received_err, "fake collector should not return an error")
      assert_equal(received_bundle.repo.root, target_root, "collector should still receive the explicit repo root")
      assert_equal(received_bundle.repo.cwd, target_root, "collector should run from the selected worktree root instead of the current plugin cwd")
    end)
  end)
end

local function test_run_collects_from_selected_worktree_root()
  local helper_calls = {
    parsed = {},
    selected = {},
    ensured = {},
    switched = {},
    bootstrapped = {},
    collected = {},
  }

  with_review_prep({
    repo = {
      parse_pr_url = function(pr_url)
        table.insert(helper_calls.parsed, pr_url)
        return {
          owner = "Owner",
          repo = "Repo",
          number = 123,
          owner_repo = "Owner/Repo",
          url = pr_url,
        }, nil
      end,
      select_repo_root = function(pr)
        table.insert(helper_calls.selected, vim.deepcopy(pr))
        return {
          repo_root = "/host/repo",
          owner_repo = "Owner/Repo",
        }, nil
      end,
      ensure_pr_worktree = function(pr, repo_root)
        table.insert(helper_calls.ensured, {
          pr = vim.deepcopy(pr),
          repo_root = repo_root,
        })
        return {
          repo_root = repo_root,
          primary_root = "/primary/repo",
          worktree_root = "/primary/repo/.worktrees/pr-123",
          owner_repo = "Owner/Repo",
          pr = pr,
        }, nil
      end,
    },
    switch = {
      execute = function(source_root, target_root)
        table.insert(helper_calls.switched, {
          source_root = source_root,
          target_root = target_root,
        })
        return {
          switched_paths = { "lua/example.lua" },
          skipped_paths = {},
        }, nil
      end,
    },
    env = {
      bootstrap = function(primary_root, target_root, allowlist)
        table.insert(helper_calls.bootstrapped, {
          primary_root = primary_root,
          target_root = target_root,
          allowlist = vim.deepcopy(allowlist),
        })
        return {
          linked = { "backend/.env" },
          reused = {},
          skipped_missing = {},
        }, nil
      end,
    },
  }, function(review_prep)
    allow_github_auth(review_prep)
    local original_allowlist = vim.g.pr_review_prep_env_allowlist
    vim.g.pr_review_prep_env_allowlist = { "backend/.env" }

    review_prep.collect = function(pr_url, opts, callback)
      table.insert(helper_calls.collected, {
        pr_url = pr_url,
        opts = vim.deepcopy(opts),
      })
      callback({
        pr = {
          url = pr_url,
          title = "Example",
          number = 123,
          owner_repo = "Owner/Repo",
          files = {},
        },
        repo = {
          root = opts.repo_root,
        },
        caveats = {},
      }, nil)
    end

    local notify_calls = {}
    with_stub(vim, "notify", function(message, level, meta)
      table.insert(notify_calls, {
        message = message,
        level = level,
        meta = meta,
      })
    end, function()
      review_prep.run("https://github.com/Owner/Repo/pull/123", {})
    end)

    vim.g.pr_review_prep_env_allowlist = original_allowlist

    assert_equal(helper_calls.parsed, {
      "https://github.com/Owner/Repo/pull/123",
    }, "run should parse the PR URL via the repo helper")
    assert_equal(#helper_calls.selected, 1, "run should select the matching repo root exactly once")
    assert_equal(helper_calls.ensured, {
      {
        pr = {
          owner = "Owner",
          repo = "Repo",
          number = 123,
          owner_repo = "Owner/Repo",
          url = "https://github.com/Owner/Repo/pull/123",
        },
        repo_root = "/host/repo",
      },
    }, "run should ensure the detached PR worktree from the selected host checkout")
    assert_equal(helper_calls.switched, {
      {
        source_root = "/host/repo",
        target_root = "/primary/repo/.worktrees/pr-123",
      },
    }, "run should switch Neovim from the host checkout into the PR worktree")
    assert_equal(helper_calls.bootstrapped, {
      {
        primary_root = "/primary/repo",
        target_root = "/primary/repo/.worktrees/pr-123",
        allowlist = { "backend/.env" },
      },
    }, "run should bootstrap the configured env allowlist from the primary checkout into the worktree")
    assert_equal(helper_calls.collected, {
      {
        pr_url = "https://github.com/Owner/Repo/pull/123",
        opts = {
          repo_root = "/primary/repo/.worktrees/pr-123",
        },
      },
    }, "collector should receive the selected PR worktree root instead of the host checkout")
    assert_truthy(#notify_calls >= 2, "run should emit progress notifications")
  end)
end

local function test_run_rejects_collector_bundle_from_wrong_repo()
  local helper_calls = {
    collected = {},
  }

  with_review_prep(nil, function(review_prep, helpers)
    allow_github_auth(review_prep)
    review_prep.collect = function(pr_url, opts, callback)
      table.insert(helper_calls.collected, {
        pr_url = pr_url,
        opts = vim.deepcopy(opts),
      })
      callback({
        pr = {
          url = pr_url,
          title = "Example",
          number = 123,
          owner_repo = "Owner/Repo",
          files = {},
        },
        repo = {
          root = "/Users/alessandroaffinito/.config/nvim/.worktrees/pr-review-prep",
          owner_repo = "tuxerrante/dot-config-nvim",
          branch = "alessandro/pr-review-prep",
          has_git = true,
        },
        caveats = {},
      }, nil)
    end

    local notify_calls = {}
    with_stub(vim, "notify", function(message, level, meta)
      table.insert(notify_calls, {
        message = message,
        level = level,
        meta = meta,
      })
    end, function()
      review_prep.run("https://github.com/Owner/Repo/pull/123", {})
    end)

    assert_equal(helper_calls.collected, {
      {
        pr_url = "https://github.com/Owner/Repo/pull/123",
        opts = {
          repo_root = "/primary/repo/.worktrees/pr-123",
        },
      },
    }, "run should still collect against the resolved PR worktree root before validating the bundle")
    assert_equal(#helpers.claude.sent, 0, "mismatched repo bundle should not be handed off to Claude Code")
    assert_equal(helpers.claude.opened, 0, "mismatched repo bundle should not open Claude Code")
    assert_equal(notify_calls[1].message, "Collecting review context bundle...", "run should still emit the collection progress notification")
    assert_match(
      notify_calls[2].message,
      "collector returned repo context for `tuxerrante/dot-config-nvim`",
      "run should surface a clear repo mismatch error instead of silently using the wrong checkout"
    )
  end)
end

local function test_run_refresh_only_changes_collector_opts()
  local helper_calls = {
    selected = {},
    ensured = {},
    switched = {},
    bootstrapped = {},
    collected = {},
  }

  with_review_prep({
    repo = {
      parse_pr_url = function(pr_url)
        return {
          owner = "Owner",
          repo = "Repo",
          number = 123,
          owner_repo = "Owner/Repo",
          url = pr_url,
        }, nil
      end,
      select_repo_root = function(pr)
        table.insert(helper_calls.selected, pr.url)
        return {
          repo_root = "/host/repo",
          owner_repo = "Owner/Repo",
        }, nil
      end,
      ensure_pr_worktree = function(pr, repo_root)
        table.insert(helper_calls.ensured, {
          pr_url = pr.url,
          repo_root = repo_root,
        })
        return {
          repo_root = repo_root,
          primary_root = "/primary/repo",
          worktree_root = "/primary/repo/.worktrees/pr-123",
          owner_repo = "Owner/Repo",
          pr = pr,
        }, nil
      end,
    },
    switch = {
      execute = function(source_root, target_root)
        table.insert(helper_calls.switched, { source_root, target_root })
        return {
          switched_paths = {},
          skipped_paths = {},
        }, nil
      end,
    },
    env = {
      bootstrap = function(primary_root, target_root, allowlist)
        table.insert(helper_calls.bootstrapped, {
          primary_root = primary_root,
          target_root = target_root,
          allowlist = vim.deepcopy(allowlist),
        })
        return {
          linked = {},
          reused = {},
          skipped_missing = {},
        }, nil
      end,
    },
  }, function(review_prep)
    allow_github_auth(review_prep)
    local original_allowlist = vim.g.pr_review_prep_env_allowlist
    vim.g.pr_review_prep_env_allowlist = {}

    review_prep.collect = function(pr_url, opts, callback)
      table.insert(helper_calls.collected, {
        pr_url = pr_url,
        opts = vim.deepcopy(opts),
      })
      callback({
        pr = {
          url = pr_url,
          title = "Example",
          number = 123,
          owner_repo = "Owner/Repo",
          files = {},
        },
        repo = {
          root = opts.repo_root,
        },
        caveats = {},
      }, nil)
    end

    with_stub(vim, "notify", function() end, function()
      review_prep.run("https://github.com/Owner/Repo/pull/123", {})
      review_prep.run("https://github.com/Owner/Repo/pull/123", { refresh = true })
    end)

    vim.g.pr_review_prep_env_allowlist = original_allowlist

    assert_equal(helper_calls.selected, {
      "https://github.com/Owner/Repo/pull/123",
      "https://github.com/Owner/Repo/pull/123",
    }, "repo selection should be unaffected by refresh")
    assert_equal(helper_calls.ensured, {
      {
        pr_url = "https://github.com/Owner/Repo/pull/123",
        repo_root = "/host/repo",
      },
      {
        pr_url = "https://github.com/Owner/Repo/pull/123",
        repo_root = "/host/repo",
      },
    }, "worktree reuse should be unaffected by refresh")
    assert_equal(helper_calls.switched, {
      { "/host/repo", "/primary/repo/.worktrees/pr-123" },
      { "/host/repo", "/primary/repo/.worktrees/pr-123" },
    }, "buffer switching should target the same worktree with or without refresh")
    assert_equal(helper_calls.bootstrapped, {
      {
        primary_root = "/primary/repo",
        target_root = "/primary/repo/.worktrees/pr-123",
        allowlist = {},
      },
      {
        primary_root = "/primary/repo",
        target_root = "/primary/repo/.worktrees/pr-123",
        allowlist = {},
      },
    }, "env bootstrap should be identical with or without refresh")
    assert_equal(helper_calls.collected, {
      {
        pr_url = "https://github.com/Owner/Repo/pull/123",
        opts = {
          repo_root = "/primary/repo/.worktrees/pr-123",
        },
      },
      {
        pr_url = "https://github.com/Owner/Repo/pull/123",
        opts = {
          refresh = true,
          repo_root = "/primary/repo/.worktrees/pr-123",
        },
      },
    }, "refresh should only add the collector refresh flag while keeping the selected worktree root")
  end)
end

-- Runs the full flow against a canned bundle and returns the notifications.
local function run_with_canned_bundle(review_prep)
  allow_github_auth(review_prep)
  review_prep.collect = function(pr_url, _opts, callback)
    callback({
      pr = { url = pr_url, title = "Example", number = 123, owner_repo = "Owner/Repo", files = {} },
      repo = {
        root = "/primary/repo/.worktrees/pr-123",
        owner_repo = "Owner/Repo",
        has_git = true,
      },
      caveats = {},
    }, nil)
  end

  local notify_calls = {}
  with_stub(vim, "notify", function(message, level)
    table.insert(notify_calls, { message = message, level = level })
  end, function()
    review_prep.run("https://github.com/Owner/Repo/pull/123", {})
  end)
  return notify_calls
end

local function test_run_pastes_prompt_into_running_claude_terminal_without_submitting()
  local saved = vim.g.pr_review_prep_new_session
  vim.g.pr_review_prep_new_session = false
  with_review_prep(nil, function(review_prep, helpers)
    local notify_calls = run_with_canned_bundle(review_prep)

    assert_equal(helpers.claude.opened, 0, "a running Claude Code session should be reused, not reopened")
    assert_equal(#helpers.claude.sent, 1, "the prompt should be pasted exactly once")
    assert_equal(
      helpers.claude.sent[1].opts,
      { submit = false, focus = true },
      "the prompt must stay editable (no submit) and the terminal should take focus"
    )
    assert_match(helpers.claude.sent[1].text, "Review GitHub PR", "the pasted text should be the review prompt")
    assert_match(notify_calls[#notify_calls].message, "pasted into Claude Code", "run should say where the prompt went")
  end)
  vim.g.pr_review_prep_new_session = saved
end

local function test_run_replaces_running_claude_session_with_a_fresh_one_in_the_worktree()
  local saved_delay = vim.g.pr_review_prep_boot_delay_ms
  vim.g.pr_review_prep_boot_delay_ms = 10
  with_review_prep(nil, function(review_prep, helpers)
    local old_buf = helpers.claude.buf
    with_stub(vim, "notify", function() end, function()
      run_with_canned_bundle(review_prep)
      assert_truthy(
        vim.wait(2000, function()
          return #helpers.claude.sent == 1
        end, 20),
        "the prompt should be pasted into the new session"
      )
    end)

    assert_truthy(not vim.api.nvim_buf_is_valid(old_buf), "the previous Claude Code terminal buffer should be wiped")
    assert_equal(helpers.claude.opened, 1, "exactly one fresh session should be started")
    assert_equal(
      helpers.claude.open_opts[1],
      { cwd = "/primary/repo/.worktrees/pr-123" },
      "the fresh session must start in the review worktree, not wherever nvim was"
    )
    assert_truthy(helpers.claude.buf ~= old_buf, "the paste should land in the new terminal, not the old one")
  end)
  vim.g.pr_review_prep_boot_delay_ms = saved_delay
end

local function test_run_starts_claude_terminal_when_none_is_running()
  local saved_delay = vim.g.pr_review_prep_boot_delay_ms
  vim.g.pr_review_prep_boot_delay_ms = 10
  with_review_prep(nil, function(review_prep, helpers)
    helpers.claude.active = false
    with_stub(vim, "notify", function() end, function()
      run_with_canned_bundle(review_prep)
      assert_truthy(
        vim.wait(2000, function()
          return #helpers.claude.sent == 1
        end, 20),
        "the prompt should be pasted once the freshly opened Claude Code terminal is ready"
      )
    end)
    assert_equal(helpers.claude.opened, 1, "a missing Claude Code session should be started once")
  end)
  vim.g.pr_review_prep_boot_delay_ms = saved_delay
end

local function test_run_falls_back_to_clipboard_when_claude_never_starts()
  local saved_timeout = vim.g.pr_review_prep_boot_timeout_ms
  vim.g.pr_review_prep_boot_timeout_ms = 300
  with_review_prep(nil, function(review_prep, helpers)
    helpers.claude.active = false
    helpers.claude.never_starts = true
    local notify_calls = {}
    with_stub(vim, "notify", function(message, level)
      table.insert(notify_calls, { message = message, level = level })
    end, function()
      run_with_canned_bundle(review_prep)
      assert_truthy(
        vim.wait(3000, function()
          for _, call in ipairs(notify_calls) do
            if call.message:find("copied to the clipboard", 1, true) then
              return true
            end
          end
          return false
        end, 20),
        "a Claude Code terminal that never appears should end in the clipboard fallback"
      )
    end)
    assert_equal(#helpers.claude.sent, 0, "nothing can be pasted into a terminal that never started")
    assert_match(vim.fn.getreg('"'), "Review GitHub PR", "the prompt should still be recoverable from a register")
  end)
  vim.g.pr_review_prep_boot_timeout_ms = saved_timeout
end

local function test_run_falls_back_to_clipboard_when_claude_cannot_be_spawned()
  with_review_prep(nil, function(review_prep, helpers)
    helpers.claude.active = false
    helpers.claude.open_throws = true
    local notify_calls = run_with_canned_bundle(review_prep)

    assert_equal(#helpers.claude.sent, 0, "nothing can be pasted when the terminal fails to spawn")
    assert_match(vim.fn.getreg('"'), "Review GitHub PR", "the prompt should survive a failed spawn")
    assert_match(notify_calls[#notify_calls].message, "copied to the clipboard", "a failed spawn should be reported")
  end)
end

local function test_run_falls_back_to_clipboard_without_claudecode()
  with_review_prep(nil, function(review_prep, helpers)
    helpers.claude.available = false
    local notify_calls = run_with_canned_bundle(review_prep)

    assert_match(vim.fn.getreg('"'), "Review GitHub PR", "the prompt should land in the unnamed register")
    local last = notify_calls[#notify_calls]
    assert_match(last.message, "copied to the clipboard", "run should say it fell back to the clipboard")
    assert_equal(last.level, vim.log.levels.WARN, "the fallback should be a warning, not a silent success")
  end)
end

local function test_run_falls_back_to_clipboard_when_claude_channel_is_closed()
  local saved_delay = vim.g.pr_review_prep_boot_delay_ms
  vim.g.pr_review_prep_boot_delay_ms = 10
  with_review_prep(nil, function(review_prep, helpers)
    helpers.claude.send_ok = false
    local notify_calls = {}
    with_stub(vim, "notify", function(message, level)
      table.insert(notify_calls, { message = message, level = level })
    end, function()
      run_with_canned_bundle(review_prep)
      assert_truthy(
        vim.wait(2000, function()
          for _, call in ipairs(notify_calls) do
            if call.message:find("copied to the clipboard", 1, true) then
              return true
            end
          end
          return false
        end, 20),
        "a failed paste into the new session should be reported"
      )
    end)
    assert_match(vim.fn.getreg('"'), "Review GitHub PR", "a failed paste should keep the prompt in a register")
  end)
  vim.g.pr_review_prep_boot_delay_ms = saved_delay
end

local function test_build_prompt_reports_pr_state_instead_of_unknown_merge_state()
  with_review_prep(nil, function(review_prep)
    local function prompt_for(pr)
      pr.url = "https://github.com/Owner/Repo/pull/123"
      pr.title = "T"
      pr.owner_repo = "Owner/Repo"
      pr.files = {}
      return review_prep.build_prompt({ pr = pr, repo = {}, caveats = {} })
    end

    local merged = prompt_for({ state = "MERGED", merge_state = "UNKNOWN" })
    assert_match(merged, "state: `MERGED`", "a merged PR should say it is merged")
    assert_not_match(merged, "merge state: `UNKNOWN`", "UNKNOWN is meaningless for a merged PR and must not be shown")

    local open = prompt_for({ state = "OPEN", is_draft = true, merge_state = "DIRTY" })
    assert_match(open, "state: `OPEN` (draft), merge state: `DIRTY`", "an open PR keeps its real merge state and draft flag")

    local legacy = prompt_for({ merge_state = "BLOCKED" })
    assert_match(legacy, "merge state: `BLOCKED`", "a cached bundle without state still renders its merge state")
  end)
end

local function test_build_prompt_lists_creation_and_last_update_times()
  with_review_prep(nil, function(review_prep)
    local function prompt_for(pr)
      pr.url = "https://github.com/Owner/Repo/pull/123"
      pr.title = "T"
      pr.owner_repo = "Owner/Repo"
      pr.files = {}
      return review_prep.build_prompt({ pr = pr, repo = {}, caveats = {} })
    end

    local open = prompt_for({ state = "OPEN", created_at = "2026-10-19T09:12:03Z", updated_at = "2026-10-20T08:07:12Z" })
    assert_match(open, "created: `2026-10-19 09:12 UTC`", "the creation time should be listed")
    assert_match(open, "last updated: `2026-10-20 08:07 UTC`", "the last modification time should be listed")
    assert_not_match(open, "merged:", "an open PR has no merge time")

    local merged = prompt_for({
      state = "MERGED",
      created_at = "2026-10-19T09:12:03Z",
      updated_at = "2026-10-20T08:07:12Z",
      merged_at = "2026-10-20T08:07:12Z",
      closed_at = "2026-10-20T08:07:12Z",
    })
    assert_match(merged, "merged: `2026-10-20 08:07 UTC`", "a merged PR should say when it merged")
    assert_not_match(merged, "closed:", "closed would repeat the merge time")

    local legacy = prompt_for({ merge_state = "BLOCKED" })
    assert_not_match(legacy, "created:", "a bundle without timestamps must not invent them")
    assert_not_match(legacy, "vim.NIL", "JSON nulls must not leak into the prompt")
  end)
end

local function test_setup_registers_command()
  with_review_prep(nil, function(review_prep)
    review_prep.setup()
    local commands = vim.api.nvim_get_commands({ builtin = false })
    assert_truthy(commands.PrepReview ~= nil, "PrepReview command should be registered")
  end)
end

function M.run()
  test_build_prompt()
  test_build_prompt_caps_review_discussion_and_marks_cached_snapshot_stale()
  test_build_prompt_tolerates_null_pr_diff()
  test_build_prompt_tolerates_json_null_pr_metadata()
  test_build_prompt_tolerates_json_null_jira_fields()
  test_ensure_github_auth_requires_authenticated_gh()
  test_run_stops_before_worktree_prep_when_github_auth_fails()
  test_collect_preserves_collector_contract_with_explicit_worktree_root()
  test_collect_runs_collector_from_selected_worktree_root()
  test_run_collects_from_selected_worktree_root()
  test_run_rejects_collector_bundle_from_wrong_repo()
  test_run_refresh_only_changes_collector_opts()
  test_run_pastes_prompt_into_running_claude_terminal_without_submitting()
  test_run_replaces_running_claude_session_with_a_fresh_one_in_the_worktree()
  test_run_starts_claude_terminal_when_none_is_running()
  test_run_falls_back_to_clipboard_when_claude_never_starts()
  test_run_falls_back_to_clipboard_when_claude_cannot_be_spawned()
  test_run_falls_back_to_clipboard_without_claudecode()
  test_run_falls_back_to_clipboard_when_claude_channel_is_closed()
  test_build_prompt_reports_pr_state_instead_of_unknown_merge_state()
  test_build_prompt_lists_creation_and_last_update_times()
  test_setup_registers_command()
  print("PASS review_prep")
end

return M
