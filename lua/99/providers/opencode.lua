local BaseProvider = require("99.providers.base")
local utils = require("99.utils")

local decode_json_line = utils.decode_json_line
local truncate = utils.truncate

local TITLE = "[99.nvim]"

--- status-area lines must stay short: the visible region is only a couple of
--- rows tall and a full text part would drown it out
local STATUS_TEXT_MAX = 160

--- installed opencode major version (nil = unknown, 1 = legacy, 2 = v2)
--- v2 drops `run --no-session-persistence` in favor of server-owned sessions
--- that we delete by captured session id.
local version_major
local version_probe_started = false
--- @type (fun(major: number?): nil)[] | nil
local pending_version_callbacks

--- legacy v1 capability: `opencode run --help` listing --no-session-persistence
local no_session_support
local no_session_probe_started = false

--- opencode --format json emits newline-delimited events.  a running
--- assistant message surfaces as part.text on several event types (text,
--- message.part.updated, ...), so text extraction is type-agnostic and takes
--- the LAST non-empty payload as the final response.
---
--- @param ev any decoded event
--- @return string | nil
local function text_from_event(ev)
  if type(ev) ~= "table" then
    return nil
  end
  local part = ev.part
  if type(part) == "table" and type(part.text) == "string" then
    if vim.trim(part.text) ~= "" then
      return part.text
    end
  end
  return nil
end

--- the human-readable message of an event error.  both
--- {"type":"error","error":{"message":...}} and
--- {"type":"error","error":{"data":{"message":...}}} appear in the
--- wild.
---
--- @param ev any decoded event
--- @return string | nil
local function error_from_event(ev)
  if type(ev) ~= "table" then
    return nil
  end
  local err = ev.error
  if type(err) == "string" then
    return err
  end
  if type(err) == "table" then
    if type(err.message) == "string" then
      return err.message
    end
    local data = err.data
    if type(data) == "table" and type(data.message) == "string" then
      return data.message
    end
  end
  return nil
end

--- v2 step_finish events carry cost and token usage.  keep the row short:
--- reason, cost, output tokens.
---
--- @param part any
--- @return string | nil
local function display_step_finish(part)
  if type(part) ~= "table" then
    return nil
  end
  local bits = {}
  if type(part.reason) == "string" and part.reason ~= "" then
    table.insert(bits, part.reason)
  end
  if type(part.cost) == "number" and part.cost > 0 then
    table.insert(bits, string.format("$%.4f", part.cost))
  end
  if type(part.tokens) == "table" and type(part.tokens.output) == "number" then
    table.insert(bits, tostring(part.tokens.output) .. " out")
  end
  if #bits == 0 then
    return nil
  end
  return "step: " .. table.concat(bits, " · ")
end

--- @param part any
--- @return string
local function display_tool_use(part)
  if type(part) ~= "table" or type(part.tool) ~= "string" then
    return "tool"
  end
  local status = type(part.state) == "table" and part.state.status or nil
  if status == "completed" then
    return "tool: " .. part.tool .. " ✓"
  end
  if status == "error" then
    return "tool: " .. part.tool .. " (error)"
  end
  return "tool: " .. part.tool
end

--- @class OpenCodeProvider : _99.Providers.BaseProvider
local OpenCodeProvider = setmetatable({}, { __index = BaseProvider })

--- @param query string
--- @param context _99.Prompt
--- @return string[]
function OpenCodeProvider._build_command(_, query, context)
  local state = context._99
  local cmd = {
    "opencode",
    "run",
  }

  --- v1 supports --no-session-persistence; v2 removed the flag and manages
  --- session lifetime through the server.  while the version is unknown, do
  --- not pass a flag that a v2 binary would reject.
  if version_major == 1 then
    local wants_no_session_persistence_disabled = not state
      or state.opencode_no_session_persistence ~= false
    if
      wants_no_session_persistence_disabled
      and OpenCodeProvider._supports_no_session_persistence()
    then
      table.insert(cmd, "--no-session-persistence")
    end
  end

  table.insert(cmd, "--agent")
  table.insert(cmd, (state and state.opencode_agent) or "build")
  table.insert(cmd, "--title")
  table.insert(cmd, TITLE)
  table.insert(cmd, "--format")
  table.insert(cmd, "json")
  table.insert(cmd, "-m")
  table.insert(cmd, context.model)
  table.insert(cmd, query)
  return cmd
end

--- opencode --format json emits newline-delimited events.  Completed
--- assistant text parts arrive as {type="text", part={text=...}}; the last
--- one is the final response message.  newer servers also stream live text
--- under message.part.updated (same part.text payload), so extraction takes
--- the last non-empty text payload of any event type.
---
--- @param _ self
--- @param stdout_text string | nil
--- @return string | nil
function OpenCodeProvider._extract_response(_, stdout_text)
  if not stdout_text then
    return nil
  end

  local last_text = nil
  for _, line in ipairs(vim.split(stdout_text, "\n", { trimempty = true })) do
    local ev = decode_json_line(line)
    if ev then
      local text = text_from_event(ev)
      if text then
        last_text = text
      end
    end
  end
  return last_text
end

--- v2 can exit zero after emitting an error event (provider routing errors
--- especially).  surface the message instead of "no response".
---
--- @param _ self
--- @param stdout_text string | nil
--- @return string | nil
function OpenCodeProvider._extract_error(_, stdout_text)
  if not stdout_text then
    return nil
  end

  local last_error = nil
  for _, line in ipairs(vim.split(stdout_text, "\n", { trimempty = true })) do
    local ev = decode_json_line(line)
    if ev then
      local err = error_from_event(ev)
      if err then
        last_error = err
      end
    end
  end
  return last_error
end

--- Map a raw stdout line to the text shown in the status area.  JSON events
--- render as their meaningful payload (text part, tool call, step summary,
--- error message) instead of the raw envelope; non-JSON lines pass through
--- untouched so plain-text providers keep working.
---
--- @param _ self
--- @param line string
--- @return string | nil
function OpenCodeProvider._stdout_line_to_display(_, line)
  local trimmed = vim.trim(line or "")
  if trimmed == "" then
    return nil
  end

  local ev = decode_json_line(line)
  if not ev then
    return trimmed
  end

  local text = text_from_event(ev)
  if text then
    return truncate(text, STATUS_TEXT_MAX)
  end

  if ev.type == "tool_use" or ev.type == "tool" then
    return display_tool_use(ev.part)
  end

  if ev.type == "step_finish" then
    return display_step_finish(ev.part)
  end

  local err = error_from_event(ev)
  if err and (ev.type == "error" or ev.type == "session.error") then
    return "error: " .. truncate(err, STATUS_TEXT_MAX)
  end

  --- step_start / message / snapshot / ... carry no user-visible content
  --- worth a status row
  return nil
end

--- capture the server-assigned session id from the event stream.  every v2
--- event carries sessionID; the first one wins.  chunk boundaries can split
--- an event, so the full stdout is re-scanned when the process exits.
---
--- @param context _99.Prompt
--- @param chunk string
function OpenCodeProvider._capture_session(_, context, chunk)
  if context.opencode_session_id or type(chunk) ~= "string" then
    return
  end
  local id = chunk:match('"sessionID"%s*:%s*"(ses_[%w]+)"')
  if id then
    context.opencode_session_id = id
  end
end

--- @param context _99.Prompt
--- @return boolean
local function should_keep_session(context)
  local state = context._99
  if state and state.opencode_no_session_persistence == false then
    return true
  end
  return false
end

--- @param id string
--- @param logger _99.Logger
local function delete_session(id, logger)
  vim.system(
    { "opencode", "session", "delete", id },
    { text = true },
    function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          logger:debug(
            "opencode session delete failed",
            "id",
            id,
            "code",
            obj.code
          )
        end
      end)
    end
  )
end

--- v2 keeps sessions in the shared service.  when the user asked for no
--- session persistence, delete the exact session this request created
--- instead of sweeping by title (which can race other nvim instances).
---
--- @param context _99.Prompt
--- @param logger _99.Logger
function OpenCodeProvider._after_request(_, context, logger)
  if should_keep_session(context) then
    return
  end
  local id = context.opencode_session_id
  if id then
    delete_session(id, logger)
  end
end

--- retry bookkeeping: the aborted attempt may already have created a session;
--- delete it so a retry never leaks one, then let the retry capture its own.
---
--- @param context _99.Prompt
--- @param logger _99.Logger
function OpenCodeProvider._on_retry(_, context, logger)
  local id = context.opencode_session_id
  if id and not should_keep_session(context) then
    delete_session(id, logger)
  end
  context.opencode_session_id = nil
end

--- Cancel kills the `opencode run` client, but v2 runs against the shared
--- background service: the session keeps working server-side unless it is
--- interrupted through the api.  v1 has no api; the kill is all there is.
---
--- @param context _99.Prompt
--- @return boolean interrupted
function OpenCodeProvider.interrupt(_, context)
  if version_major ~= 2 then
    return false
  end
  local id = context.opencode_session_id
  if not id then
    return false
  end

  vim.system(
    { "opencode", "api", "post", "/api/session/" .. id .. "/interrupt" },
    { text = true },
    function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          context.logger:debug(
            "opencode session interrupt failed",
            "id",
            id,
            "code",
            obj.code
          )
        end
      end)
    end
  )
  return true
end

--- opencode's persistence layer occasionally dies mid-run ("Failed query:
--- insert into \"part\" ...", UnknownError) before the agent does any work.
--- retry once ONLY for that signature: no tool_use in the stream proves the
--- agent never ran, so re-running cannot double-apply edits.
---
--- @param _context _99.Prompt
--- @param stdout_text string
--- @return boolean
function OpenCodeProvider._should_retry(_, _context, stdout_text)
  if not stdout_text or stdout_text == "" then
    return false
  end
  local persistence_error = stdout_text:find("Failed query", 1, true)
    or stdout_text:find("UnknownError", 1, true)
  if not persistence_error then
    return false
  end
  --- the agent may have been mid-flight when the server fell over; only
  --- retry when it demonstrably had not started
  if stdout_text:find('"tool_use"', 1, true) then
    return false
  end
  return true
end

--- Ask the installed opencode for its major version, once per nvim session.
---
--- @param callback fun(major: number?): nil
function OpenCodeProvider._probe_version(callback)
  if version_major ~= nil then
    callback(version_major)
    return
  end

  if version_probe_started then
    pending_version_callbacks = pending_version_callbacks or {}
    table.insert(pending_version_callbacks, callback)
    return
  end
  version_probe_started = true
  pending_version_callbacks = { callback }

  vim.system({ "opencode", "--version" }, { text = true }, function(obj)
    vim.schedule(function()
      local major = nil
      if obj.code == 0 then
        major = tonumber((obj.stdout or ""):match("v?(%d+)"))
      end
      version_major = major
      local callbacks = pending_version_callbacks or {}
      pending_version_callbacks = nil
      for _, cb in ipairs(callbacks) do
        cb(version_major)
      end
    end)
  end)
end

--- TEST ONLY: clear the version cache so specs can exercise both branches
function OpenCodeProvider._reset_version_probe()
  version_major = nil
  version_probe_started = false
  pending_version_callbacks = nil
end

--- TEST ONLY: pin the detected version without spawning opencode
--- @param major number?
function OpenCodeProvider._test_set_version(major)
  OpenCodeProvider._reset_version_probe()
  version_major = major
end

--- Ask the installed opencode whether `opencode run` accepts
--- --no-session-persistence (v1 only), once per nvim session, then cache the
--- answer.  Stubbed out in tests; callers that need an immediate answer while
--- the probe is in flight get the conservative `false`.
---
--- @param callback fun(supported: boolean): nil
function OpenCodeProvider._probe_no_session_persistence(callback)
  if no_session_support ~= nil then
    callback(no_session_support)
    return
  end

  if no_session_probe_started then
    callback(false)
    return
  end
  no_session_probe_started = true

  vim.system({ "opencode", "run", "--help" }, { text = true }, function(obj)
    vim.schedule(function()
      no_session_support = obj.code == 0
        and (obj.stdout or ""):find("--no-session-persistence", 1, true)
          ~= nil
      callback(no_session_support)
    end)
  end)
end

--- TEST ONLY: clear the probe cache so specs can exercise both branches
function OpenCodeProvider._reset_no_session_persistence_probe()
  no_session_support = nil
  no_session_probe_started = false
end

--- @return boolean
function OpenCodeProvider._supports_no_session_persistence()
  if no_session_support ~= nil then
    return no_session_support
  end
  --- kick the probe on first use; until it resolves, stay conservative
  --- (no flag)
  OpenCodeProvider._probe_no_session_persistence(function() end)
  return false
end

--- @return string
function OpenCodeProvider._get_provider_name()
  return "OpenCodeProvider"
end

--- @return string
function OpenCodeProvider._get_default_model()
  return "opencode/claude-sonnet-4-5"
end

--- @param callback fun(models: string[]|nil, err: string|nil): nil
local function fetch_models_cli(callback)
  vim.system({ "opencode", "models" }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, "Failed to fetch models from opencode")
        return
      end
      local models = {}
      local seen = {}
      for _, line in ipairs(vim.split(obj.stdout, "\n", { trimempty = true })) do
        local id = vim.trim(line):match("^(%S+)%s+%-")
          or vim.trim(line):match("^(%S+)$")
        if id and not seen[id] then
          table.insert(models, id)
          seen[id] = true
        end
      end
      callback(models, nil)
    end)
  end)
end

--- v2 exposes the full catalog with variants through the api; emit
--- `provider/model` plus one `provider/model#variant` entry per variant so
--- the pickers can choose reasoning effort through the model ref itself.
---
--- @param callback fun(models: string[]|nil, err: string|nil): nil
local function fetch_models_v2(callback)
  vim.system(
    { "opencode", "api", "get", "/api/model" },
    { text = true },
    function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          fetch_models_cli(callback)
          return
        end
        local ok, decoded = pcall(vim.json.decode, obj.stdout or "")
        local data = ok and type(decoded) == "table" and decoded.data or nil
        if type(data) ~= "table" then
          fetch_models_cli(callback)
          return
        end

        local models = {}
        local seen = {}
        local function add(ref)
          if ref ~= "" and not seen[ref] then
            seen[ref] = true
            table.insert(models, ref)
          end
        end
        for _, entry in ipairs(data) do
          if
            type(entry) == "table"
            and type(entry.providerID) == "string"
            and type(entry.modelID) == "string"
            and entry.enabled ~= false
            and entry.status ~= "deprecated"
          then
            local ref = entry.providerID .. "/" .. entry.modelID
            add(ref)
            for _, variant in ipairs(entry.variants or {}) do
              if type(variant) == "table" and type(variant.id) == "string" then
                add(ref .. "#" .. variant.id)
              end
            end
          end
        end
        callback(models, nil)
      end)
    end
  )
end

--- @param callback fun(models: string[]|nil, err: string|nil): nil
function OpenCodeProvider.fetch_models(callback)
  OpenCodeProvider._probe_version(function(major)
    if major == 2 then
      fetch_models_v2(callback)
    else
      fetch_models_cli(callback)
    end
  end)
end

--- v2 resolves the model a session uses when none is selected.  using it
--- avoids pinning users to a hardcoded provider/model that may not exist in
--- their configuration.  v1 has no equivalent.
---
--- @param callback fun(model: string|nil, err: string|nil): nil
function OpenCodeProvider.fetch_default_model(callback)
  OpenCodeProvider._probe_version(function(major)
    if major ~= 2 then
      callback(nil, "opencode v2 required for default model lookup")
      return
    end
    vim.system(
      { "opencode", "api", "get", "/api/model/default" },
      { text = true },
      function(obj)
        vim.schedule(function()
          if obj.code ~= 0 then
            callback(nil, "Failed to fetch default model from opencode")
            return
          end
          local ok, decoded = pcall(vim.json.decode, obj.stdout or "")
          local data = ok and type(decoded) == "table" and decoded.data or nil
          if
            type(data) ~= "table"
            or type(data.providerID) ~= "string"
            or type(data.modelID) ~= "string"
          then
            callback(nil, "opencode returned an unexpected default model")
            return
          end
          callback(data.providerID .. "/" .. data.modelID, nil)
        end)
      end
    )
  end)
end

return OpenCodeProvider
