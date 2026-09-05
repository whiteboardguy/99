local RequestStatus = require("99.ops.request_status")
local Mark = require("99.ops.marks")
local geo = require("99.geo")
local make_prompt = require("99.ops.make-prompt")
local CleanUp = require("99.ops.clean-up")

local make_clean_up = CleanUp.make_clean_up
local make_observer = CleanUp.make_observer

local Range = geo.Range
local Point = geo.Point

--- Drop duplicate reference contents (first copy wins).  the same skill
--- or file can arrive twice: once via #name matching, once via @path
--- resolution.  models pay per token for both.
---
--- @param refs _99.Reference[]
--- @return _99.Reference[]
local function dedupe_refs(refs)
  local seen = {}
  local out = {}
  for _, ref in ipairs(refs) do
    if not seen[ref.content] then
      seen[ref.content] = true
      table.insert(out, ref)
    end
  end
  return out
end

--- response size guard: a replacement may be at most this many times the
--- selection's line count (plus slack) before we treat it as a whole-file
--- rewrite and refuse to apply it.  kept generous: legit skeleton
--- implementations routinely grow 4x, while true whole-file echoes are
--- caught by the file-text check below.
local MAX_RESPONSE_MULTIPLIER = 5
local MAX_RESPONSE_SLACK = 100

--- Remove a wrapping markdown code fence (```lang ... ```) when present.
--- @param lines string[]
--- @return string[]
local function strip_code_fence(lines)
  local first, last = 1, #lines
  while first <= #lines and vim.trim(lines[first]) == "" do
    first = first + 1
  end
  while last >= 1 and vim.trim(lines[last]) == "" do
    last = last - 1
  end
  if first > last then
    return lines
  end
  local opener = lines[first]:match("^```%w*%s*$")
  local closer = lines[last]:match("^```%s*$")
  if opener and closer then
    local out = {}
    for i = first + 1, last - 1 do
      table.insert(out, lines[i])
    end
    return out
  end
  return lines
end

--- Reject responses that clearly are not a replacement for the selection.
--- Agentic models commonly echo the whole file (for small files the entire
--- file is part of the surrounding context), which would otherwise be
--- inserted into the selection.
---
--- @param response string
--- @param range _99.Range
--- @return string | nil reason when the response should be rejected
local function rejection_reason(response, range)
  local lines = strip_code_fence(vim.split(response, "\n"))
  local response_text = table.concat(lines, "\n")
  if vim.trim(response_text) == "" then
    return "response was empty"
  end

  local selection_lines = #vim.split(range:to_text(), "\n")
  local limit = math.max(
    selection_lines * MAX_RESPONSE_MULTIPLIER,
    selection_lines + MAX_RESPONSE_SLACK
  )
  if #lines > limit then
    return string.format(
      "response has %d lines but the selection is only %d line(s); "
        .. "refusing to replace with what looks like a whole-file rewrite",
      #lines,
      selection_lines
    )
  end

  local file_lines = vim.api.nvim_buf_get_lines(range.buffer, 0, -1, false)
  --- only meaningful when the file is larger than the selection: a response
  --- reproducing the whole file then contains unchanged lines it should not
  --- have (when the selection IS the whole file, any response replaces it)
  if #file_lines > selection_lines then
    local file_text = vim.trim(table.concat(file_lines, "\n"))
    if file_text ~= "" then
      local trimmed = vim.trim(response_text)
      if trimmed == file_text or trimmed:find(file_text, 1, true) then
        return "response reproduces the entire file"
      end
    end
  end

  return nil
end

--- @param context _99.Prompt
--- @param opts? _99.ops.Opts
local function over_range(context, opts)
  opts = opts or {}
  local logger = context.logger:set_area("visual")

  local data = context:visual_data()
  local range = data.range
  local top_mark = Mark.mark_above_range(range)
  local bottom_mark = Mark.mark_point(range.buffer, range.end_)
  context.marks.top_mark = top_mark
  context.marks.bottom_mark = bottom_mark

  logger:debug(
    "visual request start",
    "start",
    Point.from_mark(top_mark),
    "end",
    Point.from_mark(bottom_mark)
  )

  local display_ai_status = context._99.ai_stdout_rows > 1
  local top_status = RequestStatus.new(
    250,
    context._99.ai_stdout_rows or 1,
    "Generating visual edit",
    top_mark
  )
  local bottom_status =
    RequestStatus.new(250, 1, "Generating for selection", bottom_mark)
  local clean_up = make_clean_up(function()
    top_status:stop()
    bottom_status:stop()
  end)

  local system_cmd = context._99.prompts.prompts.visual_selection(range)
  local prompt, refs = make_prompt(context, system_cmd, opts)

  context:add_prompt_content(prompt)
  context:add_references(dedupe_refs(refs))
  context:add_clean_up(clean_up)

  local prompt_chars = 0
  for _, part in ipairs(context:content()) do
    prompt_chars = prompt_chars + #part
  end
  logger:debug("visual prompt assembled", "chars", prompt_chars)

  if display_ai_status then
    top_status:push("selection: " .. range:to_string())
    top_status:push("model: " .. context.model)
  end
  top_status:start()
  bottom_status:start()
  context:start_request(make_observer(context, {
    on_start = function()
      if display_ai_status then
        top_status:push("waiting for model output...")
      end
    end,
    on_complete = function(status, response)
      if status == "cancelled" then
        logger:debug("request cancelled for visual selection, removing marks")
      elseif status == "failed" then
        logger:error(
          "request failed for visual_selection",
          "error response",
          response or "no response provided"
        )
        vim.notify(
          "[99] visual request failed: "
            .. (response or "no response provided"):sub(1, 300),
          vim.log.levels.ERROR
        )
      elseif status == "success" then
        local valid = top_mark:is_valid() and bottom_mark:is_valid()
        if not valid then
          logger:fatal(
            -- luacheck: ignore 631
            "the original visual_selection has been destroyed.  You cannot delete the original visual selection during a request"
          )
          return
        end

        local reason = rejection_reason(response, range)
        if reason then
          logger:error(
            "visual replacement rejected",
            "reason",
            reason,
            "response",
            response:sub(1, 1000)
          )
          local choice = vim.fn.confirm(
            "[99] visual replacement rejected: " .. reason .. "\nApply anyway?",
            "&Yes\n&No",
            2
          )
          if choice ~= 1 then
            vim.notify(
              "[99] visual replacement rejected: " .. reason,
              vim.log.levels.WARN
            )
            return
          end
          logger:warn(
            "visual replacement force-applied after rejection",
            "reason",
            reason
          )
        end

        local new_range = Range.from_marks(top_mark, bottom_mark)
        local lines = strip_code_fence(vim.split(response, "\n"))

        --- HACK: when the selection starts below line 1, the top mark sits at
        --- the end of the line above, so without a leading empty line the
        --- replacement would merge into that line.  a selection starting at
        --- line 1 anchors the mark at (0,0) and needs no such line.
        local top_pos = vim.api.nvim_buf_get_extmark_by_id(
          top_mark.buffer,
          top_mark.nsid,
          top_mark.id,
          {}
        )
        if top_pos[1] ~= 0 or top_pos[2] ~= 0 then
          table.insert(lines, 1, "")
        end

        new_range:replace_text(lines)
        context._99:sync()
      end
    end,
    -- formatted per-line display: provider json events arrive here as their
    -- human payload (text part, thinking, tool call, error) instead of the
    -- raw envelope
    on_stdout_line = function(line)
      if display_ai_status then
        top_status:push(RequestStatus.format_ai_line(line))
      end
    end,
  }))
end

return over_range
