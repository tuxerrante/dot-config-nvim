local M = {}

local function trim(text)
  return text:gsub("^%s+", ""):gsub("%s+$", "")
end

local function replace_word(text, word, replacement)
  replacement = replacement or ""
  return text:gsub("%f[%a]" .. word .. "%f[%A]", replacement)
end

local function split_sentences(text)
  local sentences = {}

  for sentence in text:gmatch("[^%.%!%?]+[%.%!%?]*") do
    local trimmed = trim(sentence)
    if #trimmed > 0 then
      table.insert(sentences, trimmed)
    end
  end

  return sentences
end

function M.process(text)
  if not text or text == "" then
    return ""
  end

  -- Preserve code-heavy answers rather than mangling fenced blocks.
  if text:find("```", 1, true) then
    return text
  end

  text = text:gsub("^%s*[Hh]i[,!]*%s+", "")
  text = text:gsub("^%s*[Tt]hanks[,!]*%s+", "")
  text = text:gsub("\n%s*\n+", "\n")

  local out = {}
  for _, sentence in ipairs(split_sentences(text)) do
    local rewritten = replace_word(sentence, "maybe")
    rewritten = replace_word(rewritten, "possibly")
    rewritten = replace_word(rewritten, "probably")
    rewritten = replace_word(rewritten, "typically")
    rewritten = replace_word(rewritten, "should", "can")
    rewritten = trim(rewritten)

    if #rewritten > 0 then
      table.insert(out, "- " .. rewritten)
    end

    if #out >= 12 then
      break
    end
  end

  return table.concat(out, "\n")
end

return M
