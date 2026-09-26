local BaseProvider = require("99.providers.base")
local utils = require("99.utils")

local decode_json_line = utils.decode_json_line
local truncate = utils.truncate

--- status-area lines must stay short: the visible region is only a couple of
--- rows tall and a full text part would drown it out
local STATUS_TEXT_MAX = 160

--- pi --mode json assistant text lives in message content arrays:
--- [{type = "text", text = ...}, ...].  concatenate the non-empty text
--- entries of one message into its full text.
---
--- @param content any message content array
--- @return string | nil
local function text_from_pi_content(content)
  if type(content) ~= "table" then
    return nil
  end
  local parts = {}
  for _, entry in ipairs(content) do
    if
      type(entry) == "table"
      and entry.type == "text"
      and type(entry.text) == "string"
      and vim.trim(entry.text) ~= ""
    then
      table.insert(parts, entry.text)
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "")
end

--- @class PiProvider : _99.Providers.BaseProvider
local PiProvider = setmetatable({}, { __index = BaseProvider })

--- @param query string
--- @param context _99.Prompt
--- @return string[]
function PiProvider._build_command(_, query, context)
  local thinking = "max"
  if context._99 and context._99.pi_thinking then
    thinking = context._99.pi_thinking
  end
  return {
    "pi",
    "--no-session",
    "--mode",
    "json",
    "--thinking",
    thinking,
    "--model",
    context.model,
    "-p",
    query,
  }
end

--- pi --mode json emits newline-delimited session events.  the final
--- assistant text surfaces in message_end events (message.role ==
--- "assistant" with a content array), mirrored in the agent_end messages
--- array; streaming text_end updates carry the same payload per message.
--- extraction takes the last non-empty assistant text across all three so
--- the stdout fallback never leaks a raw JSON envelope as success text.
---
--- @param _ self
--- @param stdout_text string | nil
--- @return string | nil
function PiProvider._extract_response(_, stdout_text)
  if not stdout_text then
    return nil
  end

  local last_text = nil
  for _, line in ipairs(vim.split(stdout_text, "\n", { trimempty = true })) do
    local ev = decode_json_line(line)
    if ev then
      if
        ev.type == "message_end"
        and type(ev.message) == "table"
        and ev.message.role == "assistant"
      then
        local text = text_from_pi_content(ev.message.content)
        if text then
          last_text = text
        end
      elseif ev.type == "agent_end" and type(ev.messages) == "table" then
        for _, msg in ipairs(ev.messages) do
          if type(msg) == "table" and msg.role == "assistant" then
            local text = text_from_pi_content(msg.content)
            if text then
              last_text = text
            end
          end
        end
      elseif
        ev.type == "message_update"
        and type(ev.assistantMessageEvent) == "table"
      then
        local ame = ev.assistantMessageEvent
        if
          ame.type == "text_end"
          and type(ame.content) == "string"
          and vim.trim(ame.content) ~= ""
        then
          last_text = ame.content
        end
      end
    end
  end
  return last_text
end

--- Map a raw stdout line to the text shown in the status area.  pi JSON
--- events render as their meaningful payload (streaming text, thinking,
--- tool call, error, final message) instead of the raw envelope; non-JSON
--- lines pass through untouched so plain-text output keeps working.
--- thinking deltas render under a "Thinking> " marker so reasoning stays
--- visually separate from answer text.
---
--- @param _ self
--- @param line string
--- @return string | nil nil hides the line entirely
function PiProvider._stdout_line_to_display(_, line)
  local trimmed = vim.trim(line or "")
  if trimmed == "" then
    return nil
  end

  local ev = decode_json_line(line)
  if not ev then
    return trimmed
  end

  if
    ev.type == "message_update" and type(ev.assistantMessageEvent) == "table"
  then
    local ame = ev.assistantMessageEvent
    if
      ame.type == "text_delta"
      and type(ame.delta) == "string"
      and vim.trim(ame.delta) ~= ""
    then
      return truncate(ame.delta, STATUS_TEXT_MAX)
    end
    if
      ame.type == "text_end"
      and type(ame.content) == "string"
      and vim.trim(ame.content) ~= ""
    then
      return truncate(ame.content, STATUS_TEXT_MAX)
    end
    if
      ame.type == "thinking_delta"
      and type(ame.delta) == "string"
      and vim.trim(ame.delta) ~= ""
    then
      --- thinking streams fragment by fragment; only finished blocks
      --- (thinking_end) reach the status area
      return nil
    end
    if
      ame.type == "thinking_end"
      and type(ame.content) == "string"
      and vim.trim(ame.content) ~= ""
    then
      return "Thinking> "
        .. truncate(utils.one_line(ame.content), STATUS_TEXT_MAX)
    end
    if ame.type == "toolcall_start" then
      if type(ame.toolName) == "string" and ame.toolName ~= "" then
        return "tool: " .. ame.toolName
      end
      return "tool"
    end
    return nil
  end

  if ev.type == "tool_execution_start" then
    if type(ev.toolName) == "string" and ev.toolName ~= "" then
      return "tool: " .. ev.toolName
    end
    return "tool"
  end

  if ev.type == "tool_execution_end" then
    if ev.isError then
      local result = ev.result
      if type(result) ~= "string" then
        result = vim.inspect(result)
      end
      return "error: " .. truncate(result or "", STATUS_TEXT_MAX)
    end
    return nil
  end

  if
    ev.type == "message_end"
    and type(ev.message) == "table"
    and ev.message.role == "assistant"
  then
    local text = text_from_pi_content(ev.message.content)
    if text then
      return truncate(text, STATUS_TEXT_MAX)
    end
  end

  --- session / turn_start / turn_end / agent_start / agent_end /
  --- message_start / user messages carry no user-visible content worth a
  --- status row
  return nil
end

--- @return string
function PiProvider._get_provider_name()
  return "PiProvider"
end

--- @return string
function PiProvider._get_default_model()
  return "inclusionai/ling-3.0-flash-fin:free"
end

function PiProvider.fetch_models(callback)
  vim.system({ "pi", "--list-models" }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, "Failed to fetch models from pi")
        return
      end
      --- `pi --list-models` prints a header plus whitespace-separated
      --- rows: provider, model, context, ...  the model column may carry a
      --- leading "~" marker, which is not part of the id.
      local models = {}
      local seen = {}
      for _, line in
        ipairs(vim.split(obj.stdout or "", "\n", { trimempty = true }))
      do
        local first, id = vim.trim(line):match("^(%S+)%s+(%S+)")
        if first and id and first ~= "provider" then
          id = id:gsub("^~", "")
          if id ~= "" and not seen[id] then
            table.insert(models, id)
            seen[id] = true
          end
        end
      end
      callback(models, nil)
    end)
  end)
end

--- pi thinking levels in canonical order, mirroring pi's
--- EXTENDED_THINKING_LEVELS
PiProvider.THINKING_LEVELS =
  { "off", "minimal", "low", "medium", "high", "xhigh", "max" }

--- TEST ONLY: override the models-store catalog path so specs do not touch
--- the real ~/.pi/agent directory
PiProvider._catalog_path_override = nil

--- @return string
local function pi_catalog_path()
  if PiProvider._catalog_path_override then
    return PiProvider._catalog_path_override
  end
  local dir = vim.env.PI_CODING_AGENT_DIR or vim.fn.expand("~/.pi/agent")
  return dir .. "/models-store.json"
end

--- supported thinking levels for one catalog entry, mirroring pi's
--- getSupportedThinkingLevels: non-reasoning models offer off only, null
--- map entries are hidden, and xhigh/max need an explicit mapping.
---
--- @param entry any decoded catalog model
--- @return string[]
local function pi_supported_thinking_levels(entry)
  if type(entry) ~= "table" or not entry.reasoning then
    return { "off" }
  end
  local map = entry.thinkingLevelMap
  if type(map) ~= "table" then
    map = {}
  end
  local out = {}
  for _, level in ipairs(PiProvider.THINKING_LEVELS) do
    local mapped = map[level]
    --- null entries are hidden; xhigh/max need an explicit mapping
    local hidden = mapped == vim.NIL
      or ((level == "xhigh" or level == "max") and mapped == nil)
    if not hidden then
      table.insert(out, level)
    end
  end
  return out
end

--- find a catalog entry by model id.  tries an exact match first, then
--- strips one leading provider prefix segment ("openrouter/<id>").
---
--- @param models any[] decoded catalog models
--- @param model string
--- @return any|nil
local function pi_find_model(models, model)
  for _, entry in ipairs(models) do
    if type(entry) == "table" and entry.id == model then
      return entry
    end
  end
  local stripped = model:match("^[^/]+/(.+)$")
  if stripped then
    for _, entry in ipairs(models) do
      if type(entry) == "table" and entry.id == stripped then
        return entry
      end
    end
  end
  return nil
end

--- thinking levels the given model supports, read from pi's local model
--- catalog.  falls back to the full level list when the catalog is
--- missing, unreadable, or has no entry: pi clamps unknown levels
--- server-side, so offering them never breaks a request.
---
--- @param model string
--- @param callback fun(levels: string[]|nil, err: string|nil): nil
function PiProvider.fetch_thinking_levels(model, callback)
  local ok, store = pcall(function()
    local file = assert(io.open(pi_catalog_path(), "r"))
    local content = file:read("*a")
    file:close()
    return vim.json.decode(content)
  end)
  if not ok or type(store) ~= "table" then
    callback(vim.list_extend({}, PiProvider.THINKING_LEVELS), nil)
    return
  end
  local catalog = {}
  for _, provider_data in pairs(store) do
    if
      type(provider_data) == "table"
      and type(provider_data.models) == "table"
    then
      vim.list_extend(catalog, provider_data.models)
    end
  end
  local entry = pi_find_model(catalog, model)
  if not entry then
    callback(vim.list_extend({}, PiProvider.THINKING_LEVELS), nil)
    return
  end
  callback(pi_supported_thinking_levels(entry), nil)
end

return PiProvider
