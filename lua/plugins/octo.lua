-- GitHub PR review in the editor. The LazyVim `util.octo` extra owns the
-- plugin spec, its keymaps and the picker wiring; this file only adds the
-- piece our worktree layout needs.

-- `Octo review` infers the PR from the current branch's upstream, which works
-- in a normal branch worktree but not in the detached `.worktrees/pr-<n>`
-- checkouts `:PrepReview` creates. Ask the directory name first, then
-- fall back to whatever `gh` says about the current branch.
local function resolve_pr()
  local info = require("worktree").current()
  if info and info.pr then
    return info.pr
  end

  local res = vim
    .system({ "gh", "pr", "view", "--json", "number", "--jq", ".number" }, {
      cwd = vim.fn.getcwd(),
      text = true,
    })
    :wait()
  if res.code ~= 0 then
    return nil
  end
  return tonumber(vim.trim(res.stdout or ""))
end

-- Everyday case: you are the PR author answering reviewers. The PR buffer is
-- one scrollable document containing the description, the timeline and every
-- review thread rendered inline with its file:line header, outdated and
-- resolved markers (`octo-buffer.lua:216` -> `writers.write_threads`). `]t` /
-- `[t` jump straight to those threads and `<localleader>T` lists them,
-- `<localleader>cr` replies, `<localleader>rt` resolves, and `gf` opens the
-- file a thread points at. No diff layout, no windows that vanish when the
-- cursor moves.
local function open_pr_conversation()
  local number = resolve_pr()
  if not number then
    vim.notify("octo: no PR found for this worktree, opening the PR list", vim.log.levels.INFO)
    vim.cmd("Octo pr list")
    return
  end
  vim.cmd("Octo pr edit " .. number)
end

-- Heavier case: reviewing someone else's changes line by line. `Octo review
-- browse` loads every thread into the three-pane diff layout without touching
-- GitHub; `Octo review start` inside it creates the pending review you need
-- before you can add *new* comments.
local function open_review_layout()
  local number = resolve_pr()
  if not number then
    vim.notify("octo: no PR found for this worktree, opening the PR list", vim.log.levels.INFO)
    vim.cmd("Octo pr list")
    return
  end

  -- The review commands need a PR buffer to work from, and `Octo pr edit`
  -- loads one asynchronously, so hand off as soon as that buffer lands. The
  -- subcommand is not optional: a bare `Octo review` hits `o[nil]` in octo's
  -- dispatcher and errors out.
  local id = vim.api.nvim_create_autocmd("FileType", {
    pattern = "octo",
    once = true,
    desc = "Open the Octo review layout once the PR buffer is ready",
    callback = function()
      vim.schedule(function()
        vim.cmd("Octo review browse")
      end)
    end,
  })
  -- Don't leave the hook armed if the PR buffer never opens.
  vim.defer_fn(function()
    pcall(vim.api.nvim_del_autocmd, id)
  end, 30000)

  vim.cmd("Octo pr edit " .. number)
end

return {
  {
    "pwntester/octo.nvim",
    optional = true,
    init = function()
      -- Octo renders a thread into the *opposite* diff window while the cursor
      -- sits on a commented line, and swaps the base diff back the moment it
      -- moves off. So the thread is only reachable for as long as you do not
      -- move, which makes replying impossible: `<localleader>cr` is a
      -- `review_thread` mapping and only exists inside the thread buffer.
      --
      -- `Octo review thread` renders the thread *and* moves the cursor into
      -- it, which makes it stay put. It ships without a mapping, and review
      -- diff buffers keep the reviewed file's own filetype (yaml, sh, ...) so
      -- there is no FileType hook to hang one on -- octo marks them with a
      -- buffer variable instead.
      vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter" }, {
        group = vim.api.nvim_create_augroup("octo_review_diff_keys", { clear = true }),
        desc = "Add a stay-open thread mapping to Octo review diff buffers",
        callback = function(args)
          local ok, props = pcall(vim.api.nvim_buf_get_var, args.buf, "octo_diff_props")
          if not ok or not props then
            return
          end
          vim.keymap.set("n", "<localleader>t", "<cmd>Octo review thread<cr>", {
            buffer = args.buf,
            desc = "Open thread under cursor and jump into it (Octo)",
          })
        end,
      })

      -- In the PR buffer every review thread is rendered after the description
      -- and the whole timeline, so the comments you actually came for sit at
      -- the bottom, behind whatever Copilot wrote. Octo's `]c` / `[c` walk
      -- *every* comment, which means paging through that review to get there.
      -- These go thread to thread instead. See lua/octo_threads.lua.
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("octo_thread_nav", { clear = true }),
        pattern = "octo",
        desc = "Add review thread navigation to Octo buffers",
        callback = function(args)
          local map = function(lhs, rhs, desc)
            vim.keymap.set("n", lhs, rhs, { buffer = args.buf, desc = desc })
          end
          map("]t", function()
            require("octo_threads").jump(1)
          end, "Next review thread (Octo)")
          map("[t", function()
            require("octo_threads").jump(-1)
          end, "Prev review thread (Octo)")
          map("<localleader>T", function()
            require("octo_threads").pick()
          end, "List review threads (Octo)")
          -- `<cr>` on a thread goes where you are looking: the file and line
          -- the comment is attached to. Octo's own `<cr>` (the PR action menu)
          -- moves to `<localleader>o` in `opts` below -- octo applies its
          -- mappings after this `FileType` hook, so it would win otherwise.
          map("<cr>", function()
            require("octo_threads").goto_source()
          end, "Go to the code this thread comments on (Octo)")
        end,
      })
    end,
    opts = {
      -- The LazyVim extra turns this on. Octo checks for the `read:project`
      -- scope before adding the ProjectsV2 *query* fragment, but its
      -- ProjectsV2 *timeline* fragments are gated on this flag alone, so a
      -- token without the scope gets a GraphQL error on the `status` field
      -- as soon as a PR timeline is drawn. Grant the scope with
      -- `gh auth refresh -h github.com -s read:project` if you want these
      -- timeline events back.
      default_to_projects_v2 = false,

      mappings = {
        pull_request = {
          -- Octo binds `<cr>` in a PR buffer to a 44-entry action menu that
          -- opens with "Close PR", "Squash and Merge" and "Update Base
          -- Branch" -- irreversible actions one keystroke away from the key
          -- you press to follow something. The menu is still there, just not
          -- on `<cr>`.
          pr_options = { lhs = "<localleader>o", desc = "show PR options" },
        },
      },

      reviews = {
        -- Off by design. With this on, moving the cursor onto a commented line
        -- replaces the base diff window with the thread, and moving off swaps
        -- it back, so threads flicker in and out as you scroll and you can
        -- never get *into* one to reply. `<localleader>t` (below) opens the
        -- thread under the cursor and jumps into it, where it stays.
        auto_show_threads = false,
      },
    },
    keys = {
      { "<leader>gv", open_pr_conversation, desc = "This worktree's PR + comments (Octo)" },
      { "<leader>gV", open_review_layout, desc = "This worktree's PR review diff (Octo)" },
    },
  },
  {
    "folke/snacks.nvim",
    optional = true,
    keys = {
      {
        "<leader>gw",
        function()
          require("worktree").pick()
        end,
        desc = "Worktrees",
      },
    },
  },
}
