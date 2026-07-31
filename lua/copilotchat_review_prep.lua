local M = {}
local review_env = require("copilotchat_review_env")
local review_repo = require("copilotchat_review_repo")
local review_switch = require("copilotchat_review_switch")

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "CopilotPrepReview" })
end

local function normalized_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

local function plugin_root()
  return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
end

local function collector_path()
  return vim.g.copilot_prep_review_collector or (plugin_root() .. "/scripts/copilot_prep_review.py")
end

local function python_bin()
  return vim.g.copilot_prep_review_python or "python3"
end

local function cache_dir()
  return vim.g.copilot_prep_review_cache_dir or (vim.fn.stdpath("cache") .. "/copilot-prep-review")
end

local function maybe_string(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  return value
end

local function maybe_table(value)
  if type(value) ~= "table" then
    return nil
  end
  return value
end

local function single_line(text)
  text = maybe_string(text)
  if not text then
    return nil
  end

  local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local parts = {}
  for line in normalized:gmatch("[^\n]+") do
    local trimmed = vim.trim(line)
    if trimmed ~= "" then
      table.insert(parts, trimmed)
    end
  end

  local joined = table.concat(parts, " / ")
  if #joined > 220 then
    joined = joined:sub(1, 217):gsub("%s+$", "") .. "..."
  end
  return joined
end

local function github_pr_url(url)
  if type(url) ~= "string" then
    return false
  end

  return url:match("^https?://github%.com/[^/]+/[^/]+/pull/%d+/?$")
end

local function resolve_step(invoke, callback)
  local done = false

  local function finish(result, err)
    if done then
      return
    end
    done = true
    callback(result, err)
  end

  local result, err = invoke(finish)
  if result ~= nil or err ~= nil then
    finish(result, err)
  end
end

local function prepare_worktree(pr_url, callback)
  local pr, pr_err = review_repo.parse_pr_url(pr_url)
  if pr_err then
    callback(nil, pr_err)
    return
  end

  resolve_step(function(on_done)
    return review_repo.select_repo_root(pr, on_done)
  end, function(repo_match, repo_err)
    if repo_err then
      callback(nil, repo_err)
      return
    end

    resolve_step(function(on_done)
      return review_repo.ensure_pr_worktree(pr, repo_match.repo_root, on_done)
    end, function(worktree, worktree_err)
      if worktree_err then
        callback(nil, worktree_err)
        return
      end

      resolve_step(function(on_done)
        return review_switch.execute(repo_match.repo_root, worktree.worktree_root, on_done)
      end, function(_, switch_err)
        if switch_err then
          callback(nil, switch_err)
          return
        end

        local allowlist = vim.g.copilot_prep_review_env_allowlist or {}
        local _, env_err = review_env.bootstrap(worktree.primary_root, worktree.worktree_root, allowlist)
        if env_err then
          callback(nil, env_err)
          return
        end

        callback(worktree, nil)
      end)
    end)
  end)
end

local function detect_repo_root()
  local cwd = vim.uv.cwd()
  if not cwd or cwd == "" then
    return nil
  end

  local root = vim.fs.root(cwd, ".git")
  if root and root ~= "" then
    return root
  end

  local out = vim.system({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }, { text = true }):wait()
  if out.code == 0 then
    local value = vim.trim(out.stdout or "")
    return value ~= "" and value or nil
  end

  return nil
end

local function repo_mismatch_error(actual_repo, actual_root, expected_repo, expected_root)
  return string.format(
    "collector returned repo context for `%s` at `%s`, expected `%s` at `%s`",
    actual_repo or "unknown",
    actual_root or "unknown",
    expected_repo or "unknown",
    expected_root or "unknown"
  )
end

local function validate_collected_repo_context(bundle, worktree)
  local repo = type(bundle) == "table" and bundle.repo or {}
  local expected_root = normalized_path(worktree and worktree.worktree_root)
  local actual_root = normalized_path(repo and repo.root)
  local expected_repo = worktree and worktree.owner_repo or nil
  local actual_repo = repo and repo.owner_repo or nil

  if actual_root ~= expected_root then
    return nil, repo_mismatch_error(actual_repo, repo and repo.root, expected_repo, worktree and worktree.worktree_root)
  end

  if actual_repo ~= expected_repo then
    return nil, repo_mismatch_error(actual_repo, repo and repo.root, expected_repo, worktree and worktree.worktree_root)
  end

  return true, nil
end

local function focus_chat_input(chat)
  chat.chat:focus()
  if chat.config and chat.config.auto_insert_mode then
    vim.cmd("startinsert")
  end
end

local function handoff_prompt(prompt)
  local chat = require("CopilotChat")
  local constants = require("CopilotChat.constants")

  chat.open()
  chat.chat:add_message({
    role = constants.ROLE.USER,
    content = prompt,
  }, true)
  focus_chat_input(chat)
end

local function render_section(title, rows)
  if not rows or vim.tbl_isempty(rows) then
    return nil
  end

  return title .. "\n" .. table.concat(rows, "\n")
end

local function text_lines(text, limit)
  if type(text) ~= "string" or text == "" then
    return {}
  end

  local lines = {}
  for line in text:gsub("\r\n", "\n"):gsub("\r", "\n"):gmatch("[^\n]+") do
    local trimmed = vim.trim(line)
    if trimmed ~= "" then
      table.insert(lines, trimmed)
    end
    if limit and #lines >= limit then
      break
    end
  end
  return lines
end

local function bullet(text)
  return "- " .. text
end

local function summarize_path_item(item)
  local excerpt = single_line(item.excerpt) or "no excerpt captured"
  return bullet(string.format("%s `%s`: %s", item.provenance or "source", item.path, excerpt))
end

local function summarize_gate(item)
  local note = single_line(item.note) or "relevant validation command"
  return bullet(string.format("`%s` (%s): %s", item.command, item.source or "source", note))
end

local function summarize_related(item)
  local reason = item.reason and ("matched " .. item.reason) or "related PR"
  return bullet(string.format("[#%s](%s) %s (%s)", item.number, item.url, item.title or "", reason))
end

local function summarize_jira(item)
  item = maybe_table(item) or {}
  local summary = item.summary and single_line(item.summary) or "summary unavailable"
  local status_value = maybe_string(item.status)
  local status = status_value and (" [" .. status_value .. "]") or ""
  local key = maybe_string(item.key) or "unknown"
  local url = maybe_string(item.url)
  local ref = url and string.format("[%s](%s)", key, url) or key
  local parts = { string.format("%s%s: %s", ref, status, summary) }

  local parent = maybe_table(item.epic) or maybe_table(item.parent)
  if parent and parent.key then
    local parent_key = maybe_string(parent.key) or "unknown"
    local parent_url = maybe_string(parent.url)
    local parent_ref = parent_url and string.format("[%s](%s)", parent_key, parent_url) or parent_key
    local parent_type = maybe_string(parent.issue_type) or (maybe_table(item.epic) and "Epic") or "Parent"
    local parent_summary = parent.summary and single_line(parent.summary) or "summary unavailable"
    table.insert(
      parts,
      string.format("%s %s [%s]: %s", parent_type, parent_ref, maybe_string(parent.status) or "unknown", parent_summary)
    )
  end

  local linked = maybe_table(item.linked_issues) or {}
  if #linked > 0 then
    local linked_parts = {}
    for index, linked_item in ipairs(linked) do
      if index > 3 then
        table.insert(linked_parts, string.format("+%d more", #linked - 3))
        break
      end

      local linked_key = maybe_string(linked_item.key) or "unknown"
      local linked_url = maybe_string(linked_item.url)
      local linked_ref = linked_url and string.format("[%s](%s)", linked_key, linked_url) or linked_key
      local linked_summary = linked_item.summary and single_line(linked_item.summary) or "summary unavailable"
      local relation_value = maybe_string(linked_item.relation)
      local relation = relation_value and (relation_value .. ": ") or ""
      table.insert(
        linked_parts,
        string.format("%s%s [%s] %s", relation, linked_ref, maybe_string(linked_item.status) or "unknown", linked_summary)
      )
    end
    table.insert(parts, "Linked: " .. table.concat(linked_parts, " | "))
  end

  return bullet(table.concat(parts, " / "))
end

local function summarize_conversation(item, status)
  local label = item.label or item.path or "unknown thread"
  local summary = single_line(item.summary) or "discussion summary unavailable"
  return bullet(string.format("%s [%s]: %s", label, status, summary))
end

local function summarize_top_level_comment(item)
  local author = item.author or "unknown commenter"
  local summary = single_line(item.summary) or "discussion summary unavailable"
  return bullet(string.format("%s [top-level]: %s", author, summary))
end

local function summarize_pr_conversations(conversations, cache_hit)
  if type(conversations) ~= "table" then
    return {}
  end

  local unresolved = conversations.unresolved or {}
  local resolved = conversations.resolved or {}
  local top_level = conversations.top_level or {}
  local unresolved_count = tonumber(conversations.unresolved_count) or #unresolved
  local resolved_count = tonumber(conversations.resolved_count) or #resolved
  local top_level_count = tonumber(conversations.top_level_count) or #top_level
  if unresolved_count == 0 and resolved_count == 0 and top_level_count == 0 and #unresolved == 0 and #resolved == 0 then
    return {}
  end

  local has_threads = unresolved_count > 0 or resolved_count > 0 or #unresolved > 0 or #resolved > 0
  local rows = {}
  if has_threads then
    table.insert(rows, bullet(string.format(
      "%d unresolved thread(s) prioritized; %d resolved thread(s) included to avoid repeating settled asks.",
      unresolved_count,
      math.min(resolved_count, 2)
    )))
  elseif top_level_count > 0 then
    table.insert(
      rows,
      bullet(string.format("No inline review threads were kept; %d high-signal top-level PR comment(s) added as fallback context.", top_level_count))
    )
  end

  local shown_unresolved = math.min(#unresolved, 4)
  for index = 1, shown_unresolved do
    table.insert(rows, summarize_conversation(unresolved[index], "unresolved"))
  end
  if unresolved_count > shown_unresolved then
    table.insert(rows, bullet(string.format("... plus %d more unresolved thread(s)", unresolved_count - shown_unresolved)))
  end

  local shown_resolved = math.min(#resolved, 2)
  if shown_resolved > 0 then
    table.insert(rows, bullet("Resolved threads worth not reopening:"))
    for index = 1, shown_resolved do
      table.insert(rows, summarize_conversation(resolved[index], "resolved"))
    end
    if resolved_count > shown_resolved then
      table.insert(rows, bullet(string.format("... plus %d more resolved thread(s)", resolved_count - shown_resolved)))
    end
  end

  local shown_top_level = math.min(#top_level, 2)
  if shown_top_level > 0 then
    if has_threads then
      table.insert(rows, bullet(string.format("%d high-signal top-level PR comment(s) added as secondary context.", top_level_count)))
    end
    table.insert(rows, bullet("Top-level PR comments worth keeping in mind:"))
    for index = 1, shown_top_level do
      table.insert(rows, summarize_top_level_comment(top_level[index]))
    end
    if top_level_count > shown_top_level then
      table.insert(rows, bullet(string.format("... plus %d more high-signal top-level PR comment(s)", top_level_count - shown_top_level)))
    end
  end

  if cache_hit then
    table.insert(
      rows,
      bullet("Review discussion snapshot may be stale because this bundle came from cache. Use `:CopilotPrepReview!` to refresh.")
    )
  end

  return rows
end

local function summarize_pr_diff(diff)
  if type(diff) ~= "table" then
    return {}
  end

  local rows = {}
  for _, line in ipairs(text_lines(diff.stat, 12)) do
    table.insert(rows, bullet(line))
  end
  if #rows == 0 and diff.excerpt and diff.excerpt ~= "" then
    table.insert(rows, bullet("GitHub returned raw diff detail, but this seeded prompt intentionally omits it."))
  end
  if #rows > 0 then
    table.insert(
      rows,
      bullet("Use the checked-out local worktree and live repo tools for exact hunks; this prep stays at file-level summary only.")
    )
  end
  return rows
end

function M.build_prompt(bundle)
  local pr = bundle.pr or {}
  local repo = bundle.repo or {}
  local title = pr.title or ("PR #" .. tostring(pr.number or "?"))
  local header = {
    string.format("Review GitHub PR %s: %s", pr.url or "", title),
    "",
    "Use the bundle below as the prepared first-pass context. Be explicit about missing sources or degraded lookups instead of pretending they were read.",
  }

  local facts = {
    bullet(string.format("repo: `%s`", pr.owner_repo or repo.owner_repo or "unknown")),
    bullet(string.format("base/head: `%s` <- `%s`", pr.base_ref or "unknown", pr.head_ref or "unknown")),
    bullet(string.format("author: `%s`", pr.author or "unknown")),
    bullet(string.format("merge state: `%s`", pr.merge_state or "unknown")),
    bullet(string.format("review decision: `%s`", pr.review_decision or "unknown")),
  }

  if repo.root then
    table.insert(facts, bullet(string.format("local repo root: `%s`", repo.root)))
  end
  if repo.branch then
    table.insert(facts, bullet(string.format("local branch: `%s`", repo.branch)))
  end

  local changed_files = {}
  for index, path in ipairs(pr.files or {}) do
    if index > 12 then
      table.insert(changed_files, bullet(string.format("... plus %d more file(s)", #pr.files - 12)))
      break
    end
    table.insert(changed_files, bullet(string.format("`%s`", path)))
  end

  local rules = {}
  for index, item in ipairs(bundle.rules_and_docs or {}) do
    if index > 8 then
      table.insert(
        rules,
        bullet(string.format("... plus %d more rule/doc source(s)", #(bundle.rules_and_docs or {}) - 8))
      )
      break
    end
    table.insert(rules, summarize_path_item(item))
  end

  local domain = {}
  for index, item in ipairs(bundle.domain_context or {}) do
    if index > 5 then
      table.insert(
        domain,
        bullet(string.format("... plus %d more domain-context source(s)", #(bundle.domain_context or {}) - 5))
      )
      break
    end
    table.insert(domain, summarize_path_item(item))
  end

  local pr_diff = summarize_pr_diff(bundle.pr_diff or {})
  local pr_conversations = summarize_pr_conversations(bundle.pr_conversations, bundle.cache_hit)

  local gates = {}
  for index, item in ipairs(bundle.quality_gates or {}) do
    if index > 8 then
      table.insert(
        gates,
        bullet(string.format("... plus %d more quality-gate command(s)", #(bundle.quality_gates or {}) - 8))
      )
      break
    end
    table.insert(gates, summarize_gate(item))
  end

  local related = {}
  for index, item in ipairs(bundle.related_prs or {}) do
    if index > 4 then
      table.insert(related, bullet(string.format("... plus %d more related PR(s)", #(bundle.related_prs or {}) - 4)))
      break
    end
    table.insert(related, summarize_related(item))
  end

  local jira = {}
  for index, item in ipairs(bundle.jira or {}) do
    if index > 4 then
      table.insert(jira, bullet(string.format("... plus %d more Jira ref(s)", #(bundle.jira or {}) - 4)))
      break
    end
    table.insert(jira, summarize_jira(item))
  end

  local caveats = {}
  for _, item in ipairs(bundle.caveats or {}) do
    local summary = single_line(item)
    if summary then
      table.insert(caveats, bullet(summary))
    end
  end

  local instructions = {
    "Review instructions",
    bullet("Start with correctness, regression risk, contract violations, and missing tests."),
    bullet("Honor the listed rules/docs before making repo-specific claims."),
    bullet("Treat degraded or unavailable sources as constraints, not hidden assumptions."),
    bullet(
      "Inline review threads are prioritized here, with a small set of high-signal top-level PR issue comments added as secondary context; standalone review bodies and the rest of the PR conversation are still excluded."
    ),
    bullet("If you need more context, fetch the next specific file, command, or PR and say why."),
  }

  local sections = {
    table.concat(header, "\n"),
    render_section("PR facts", facts),
    render_section("Changed files", changed_files),
    render_section("PR diff summary", pr_diff),
    render_section("Prior review discussion", pr_conversations),
    render_section("Rules and important docs", rules),
    render_section("Domain context", domain),
    render_section("Quality gates and validation commands", gates),
    render_section("Related PRs", related),
    render_section("Jira refs", jira),
    render_section("Degraded-mode caveats", caveats),
    table.concat(instructions, "\n"),
  }

  return table.concat(
    vim.tbl_filter(function(section)
      return section and section ~= ""
    end, sections),
    "\n\n"
  )
end

function M.collect(pr_url, opts, callback)
  opts = opts or {}
  local repo_root = opts.repo_root == nil and detect_repo_root() or opts.repo_root
  local argv = {
    python_bin(),
    collector_path(),
    pr_url,
    "--cache-dir",
    cache_dir(),
  }

  if repo_root and repo_root ~= "" then
    table.insert(argv, "--repo-root")
    table.insert(argv, repo_root)
  end
  if opts.refresh then
    table.insert(argv, "--refresh")
  end

  local sysopts = { text = true }
  if repo_root and repo_root ~= "" then
    -- Run the collector from the selected checkout so cwd-sensitive helpers
    -- cannot leak the plugin worktree into the prepared bundle.
    sysopts.cwd = repo_root
  end

  vim.system(argv, sysopts, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        local stderr = single_line(out.stderr or "") or single_line(out.stdout or "") or "collector failed"
        callback(nil, stderr)
        return
      end

      local ok, decoded = pcall(vim.json.decode, out.stdout or "")
      if not ok or type(decoded) ~= "table" then
        callback(nil, "collector returned invalid JSON")
        return
      end
      if decoded.error then
        callback(nil, decoded.error)
        return
      end

      callback(decoded, nil)
    end)
  end)
end

function M.run(pr_url, opts)
  opts = opts or {}
  prepare_worktree(pr_url, function(worktree, prep_err)
    if prep_err then
      notify(prep_err, vim.log.levels.ERROR)
      return
    end

    notify("Collecting review context bundle...")
    M.collect(pr_url, {
      refresh = opts.refresh,
      repo_root = worktree.worktree_root,
    }, function(bundle, err)
      if err then
        notify(err, vim.log.levels.ERROR)
        return
      end

      local _, repo_err = validate_collected_repo_context(bundle, worktree)
      if repo_err then
        notify(repo_err, vim.log.levels.ERROR)
        return
      end

      local prompt = M.build_prompt(bundle)
      handoff_prompt(prompt)

      local cache_state = bundle.cache_hit and "cache hit" or "fresh bundle"
      local caveat_count = #(bundle.caveats or {})
      notify(
        string.format(
          "Prompt prepared in CopilotChat (%s, %d caveat(s)). Press <C-j> to send.",
          cache_state,
          caveat_count
        )
      )
    end)
  end)
end

function M.setup()
  if M._commands_registered then
    return
  end

  vim.api.nvim_create_user_command("CopilotPrepReview", function(cmd)
    M.run(cmd.args, { refresh = cmd.bang })
  end, {
    bang = true,
    nargs = 1,
    desc = "Prepare a CopilotChat review prompt for a GitHub pull request",
  })

  M._commands_registered = true
end

return M
