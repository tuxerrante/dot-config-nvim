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

local function clear_review_prep_modules()
  package.loaded.copilotchat_review_prep = nil
  package.loaded.copilotchat_review_repo = nil
  package.loaded.copilotchat_review_switch = nil
  package.loaded.copilotchat_review_env = nil
  package.loaded.CopilotChat = nil
  package.loaded["CopilotChat.constants"] = nil
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
    prep = package.preload.copilotchat_review_prep,
    repo = package.preload.copilotchat_review_repo,
    switch = package.preload.copilotchat_review_switch,
    env = package.preload.copilotchat_review_env,
    chat = package.preload.CopilotChat,
    constants = package.preload["CopilotChat.constants"],
  }

  local helpers = default_helper_stubs()
  helpers.chat_state = {
    messages = {},
    opened = 0,
    focused = 0,
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

  package.preload.copilotchat_review_repo = function()
    return helpers.repo
  end
  package.preload.copilotchat_review_switch = function()
    return helpers.switch
  end
  package.preload.copilotchat_review_env = function()
    return helpers.env
  end
  package.preload.CopilotChat = function()
    return {
      config = { auto_insert_mode = false },
      open = function()
        helpers.chat_state.opened = helpers.chat_state.opened + 1
      end,
      chat = {
        focus = function()
          helpers.chat_state.focused = helpers.chat_state.focused + 1
        end,
        add_message = function(_, message)
          table.insert(helpers.chat_state.messages, message)
        end,
      },
      _messages = helpers.chat_state.messages,
    }
  end
  package.preload["CopilotChat.constants"] = function()
    return {
      ROLE = {
        USER = "user",
      },
    }
  end

  local ok, result = xpcall(function()
    local review_prep = require("copilotchat_review_prep")
    return fn(review_prep, helpers)
  end, debug.traceback)

  package.preload.copilotchat_review_prep = saved_preload.prep
  package.preload.copilotchat_review_repo = saved_preload.repo
  package.preload.copilotchat_review_switch = saved_preload.switch
  package.preload.copilotchat_review_env = saved_preload.env
  package.preload.CopilotChat = saved_preload.chat
  package.preload["CopilotChat.constants"] = saved_preload.constants
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
            label = "tests/test_copilot_prep_review.py:210",
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
      "Review discussion snapshot may be stale because this bundle came from cache. Use `:CopilotPrepReview!` to refresh.",
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
        vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/scripts/copilot_prep_review.py",
        "https://github.com/Owner/Repo/pull/123",
        "--cache-dir",
        vim.fn.stdpath("cache") .. "/copilot-prep-review",
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

local function test_collect_runs_collector_from_selected_worktree_root()
  with_review_prep(nil, function(review_prep)
    with_temp_dir("copilot-review-collector", function(root)
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

      local original_collector = vim.g.copilot_prep_review_collector
      local original_cache_dir = vim.g.copilot_prep_review_cache_dir
      local original_cwd = vim.uv.cwd()
      vim.g.copilot_prep_review_collector = collector
      vim.g.copilot_prep_review_cache_dir = cache_dir
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

      vim.g.copilot_prep_review_collector = original_collector
      vim.g.copilot_prep_review_cache_dir = original_cache_dir
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
    local original_allowlist = vim.g.copilot_prep_review_env_allowlist
    vim.g.copilot_prep_review_env_allowlist = { "backend/.env" }

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

    vim.g.copilot_prep_review_env_allowlist = original_allowlist

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
          root = "/Users/alessandroaffinito/.config/nvim/.worktrees/copilot-prep-review",
          owner_repo = "tuxerrante/dot-config-nvim",
          branch = "alessandro/copilot-prep-review",
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
    assert_equal(#helpers.chat_state.messages, 0, "mismatched repo bundle should not be handed off to CopilotChat")
    assert_equal(helpers.chat_state.opened, 0, "mismatched repo bundle should not open CopilotChat")
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
    local original_allowlist = vim.g.copilot_prep_review_env_allowlist
    vim.g.copilot_prep_review_env_allowlist = {}

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

    vim.g.copilot_prep_review_env_allowlist = original_allowlist

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

local function test_setup_registers_command()
  with_review_prep(nil, function(review_prep)
    review_prep.setup()
    local commands = vim.api.nvim_get_commands({ builtin = false })
    assert_truthy(commands.CopilotPrepReview ~= nil, "CopilotPrepReview command should be registered")
  end)
end

function M.run()
  test_build_prompt()
  test_build_prompt_caps_review_discussion_and_marks_cached_snapshot_stale()
  test_build_prompt_tolerates_null_pr_diff()
  test_build_prompt_tolerates_json_null_jira_fields()
  test_collect_preserves_collector_contract_with_explicit_worktree_root()
  test_collect_runs_collector_from_selected_worktree_root()
  test_run_collects_from_selected_worktree_root()
  test_run_rejects_collector_bundle_from_wrong_repo()
  test_run_refresh_only_changes_collector_opts()
  test_setup_registers_command()
  print("PASS copilotchat_review_prep")
end

return M
