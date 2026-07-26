-- caveman: post-process assistant output to shorter, denser form
-- This is a naive implementation: it strips pleasantries and collapses
-- sentences to bullets. Use by piping assistant text through caveman.process(text).

local M = {}

local function split_sentences(s)
  local t = {}
  for sent in s:gmatch("[^%.%!%?]+[%.%!%?]*") do
    sent = sent:gsub("^%s+",""):gsub("%s+$","")
    if #sent > 0 then table.insert(t, sent) end
  end
  return t
end

function M.process(text)
  if not text or text == "" then return "" end
  -- remove polite preambles
  text = text:gsub("^%s*[Hh]i[,!]*%s+","")
  text = text:gsub("^%s*[Tt]hanks[,!]*%s+","")
  -- collapse multiple blank lines
  text = text:gsub("\n%\s*\n+","\n")

  local sents = split_sentences(text)
  local out = {}
  for i, sent in ipairs(sents) do
    -- shorten hedging
    sent = sent:gsub("\bmaybe\b","")
    sent = sent:gsub("\bpossibly\b","")
    sent = sent:gsub("\bprobably\b","")
    sent = sent:gsub("\btypically\b","")
    sent = sent:gsub("\bshould\b","can")
    -- trim
    sent = sent:gsub("^%s+",""):gsub("%s+$","")
    if #sent > 0 then
      table.insert(out, "- " .. sent)
    end
    if #out >= 12 then break end
  end
  return table.concat(out, "\n")
end

return M
