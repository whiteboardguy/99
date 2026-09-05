--- @class _99.Providers.Observer
--- @field on_stdout fun(line: string): nil raw stdout chunk, verbatim
--- @field on_stdout_line? fun(line: string): nil formatted single line for display
--- @field on_stderr fun(line: string): nil
--- @field on_complete fun(status: _99.Prompt.EndingState, res: string): nil
--- @field on_start fun(): nil

--- @param fn fun(...: any): nil
--- @return fun(...: any): nil
local function once(fn)
  local called = false
  return function(...)
    if called then
      return
    end
    called = true
    fn(...)
  end
end

--- @class _99.Providers.BaseProvider
--- @field _build_command fun(self: _99.Providers.BaseProvider, query: string, context: _99.Prompt): string[]
--- @field _get_provider_name fun(self: _99.Providers.BaseProvider): string
--- @field _get_default_model fun(): string
local BaseProvider = {}

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

--- status-area lines must stay short: the visible region is only a couple of
--- rows tall and a full text part would drown it out
local STATUS_TEXT_MAX = 160

--- @param text string
--- @return string
local function truncate_status(text)
  if #text <= STATUS_TEXT_MAX then
    return text
  end
  return text:sub(1, STATUS_TEXT_MAX) .. " …"
end

--- status rows render as single virtual-text lines: collapse embedded
--- newlines in streamed payloads (reasoning especially) into spaces.
---
--- @param text string
--- @return string
local function one_line(text)
  return vim.trim(text:gsub("[\r\n]+", " "))
end

--- whether the installed opencode supports `--no-session-persistence`
--- (nil = unknown, false = unsupported, true = supported)
local opencode_no_session_support
local opencode_probe_started = false
--- @type (fun(supported: boolean): nil)[] | nil
local pending_probe_callbacks

--- session cleanup spawns `opencode session list` + one delete per session;
--- debounce it so we do not spawn a process tree after every single request
local SESSION_CLEANUP_INTERVAL_MS = 30 * 1000
local last_session_cleanup = 0

local function cleanup_99_opencode_sessions(logger)
  local now = vim.uv.now()
  if now - last_session_cleanup < SESSION_CLEANUP_INTERVAL_MS then
    return
  end
  last_session_cleanup = now

  vim.system(
    { "opencode", "session", "list" },
    { text = true },
    function(list_obj)
      vim.schedule(function()
        if list_obj.code ~= 0 then
          logger:debug(
            "cleanup_99_opencode_sessions: list failed",
            "code",
            list_obj.code
          )
          return
        end

        local ids = {}
        for _, line in
          ipairs(vim.split(list_obj.stdout or "", "\n", { trimempty = true }))
        do
          if line:find("%[99%.nvim%]", 1, false) then
            local id = vim.trim(line):match("^(%S+)")
            if id then
              table.insert(ids, id)
            end
          end
        end

        for _, id in ipairs(ids) do
          vim.system(
            { "opencode", "session", "delete", id },
            { text = true },
            function(delete_obj)
              vim.schedule(function()
                if delete_obj.code ~= 0 then
                  logger:debug(
                    "cleanup_99_opencode_sessions: delete failed",
                    "id",
                    id,
                    "code",
                    delete_obj.code
                  )
                end
              end)
            end
          )
        end
      end)
    end
  )
end

--- @param command string[]
--- @param extra_args string[]
local function add_args_before_prompt(command, extra_args)
  if #extra_args == 0 then
    return command
  end
  -- Provider command builders place the user prompt as the final positional arg.
  -- Injecting provider_extra_args before that preserves CLI flag parsing.
  local prompt = table.remove(command)
  vim.list_extend(command, extra_args)
  table.insert(command, prompt)
  return command
end

--- @param callback fun(models: string[]|nil, err: string|nil): nil
function BaseProvider.fetch_models(callback)
  callback(nil, "This provider does not support listing models")
end

--- @param context _99.Prompt
function BaseProvider:_retrieve_response(context)
  local logger = context.logger:set_area(self:_get_provider_name())
  local tmp = context.tmp_file
  local success, result = pcall(function()
    return vim.fn.readfile(tmp)
  end)

  if not success then
    logger:error(
      "retrieve_results: failed to read file",
      "tmp_name",
      tmp,
      "error",
      result
    )
    return false, ""
  end

  local str = table.concat(result, "\n")
  logger:debug("retrieve_results", "results", str)

  return true, str
end

--- @param stdout_text string | nil
--- @return string | nil
function BaseProvider._extract_response(_, stdout_text)
  if not stdout_text or vim.trim(stdout_text) == "" then
    return nil
  end
  return vim.trim(stdout_text)
end

--- Turn one raw stdout line into the text shown in the status area.
--- Providers override this to render their machine-readable output; the
--- default treats output as already human-readable.
---
--- @param _ self
--- @param line string
--- @return string | nil nil hides the line entirely
function BaseProvider._stdout_line_to_display(_, line)
  local trimmed = vim.trim(line or "")
  if trimmed == "" then
    return nil
  end
  return trimmed
end

--- @param query string
--- @param context _99.Prompt
--- @param observer _99.Providers.Observer
function BaseProvider:make_request(query, context, observer)
  observer.on_start()

  local logger = context.logger:set_area(self:_get_provider_name())
  logger:debug("make_request", "tmp_file", context.tmp_file)

  --- opencode's persistence layer occasionally dies mid-run ("Failed query:
  --- insert into \"part\" ...", UnknownError) before the agent does any
  --- work.  retry once ONLY for that signature: no tool_use in the stream
  --- proves the agent never ran, so re-running cannot double-apply edits.
  local MAX_ATTEMPTS = 2
  local attempts = 0

  --- @param stdout_text string
  --- @return boolean
  local function should_retry(stdout_text)
    if attempts >= MAX_ATTEMPTS then
      return false
    end
    if self:_get_provider_name() ~= "OpenCodeProvider" then
      return false
    end
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

  --- @type fun(): nil
  local run
  run = function()
    attempts = attempts + 1

    local once_complete = once(
      --- @param status "success" | "failed" | "cancelled"
      ---@param text string
      function(status, text)
        observer.on_complete(status, text)
      end
    )

    local command = self:_build_command(query, context)
    local extra_args = context._99 and context._99.provider_extra_args or {}
    add_args_before_prompt(command, extra_args)
    logger:debug("make_request", "command", command)
    local stdout_chunks = {}
    local stderr_chunks = {}

    --- vim.system chunks can split a JSON event mid-line; buffer the
    --- incomplete trailing segment instead of dumping fragments into the
    --- status area
    local display_pending = ""
    local function flush_display_pending()
      if display_pending == "" or not observer.on_stdout_line then
        return
      end
      local display = self:_stdout_line_to_display(display_pending)
      if display then
        observer.on_stdout_line(display)
      end
      display_pending = ""
    end

    local proc = vim.system(
      command,
      {
        text = true,
        stdout = vim.schedule_wrap(function(err, data)
          logger:debug("stdout", "data", data)
          if context:is_cancelled() then
            once_complete("cancelled", "")
            return
          end
          if err and err ~= "" then
            logger:debug("stdout#error", "err", err)
          end
          if not err and data then
            table.insert(stdout_chunks, data)
            observer.on_stdout(data)
            if observer.on_stdout_line then
              display_pending = display_pending .. data
              local lines =
                vim.split(display_pending, "\n", { trimempty = false })
              display_pending = table.remove(lines) or ""
              for _, line in ipairs(lines) do
                local display = self:_stdout_line_to_display(line)
                if display then
                  observer.on_stdout_line(display)
                end
              end
            end
          end
        end),
        stderr = vim.schedule_wrap(function(err, data)
          logger:debug("stderr", "data", data)
          if context:is_cancelled() then
            once_complete("cancelled", "")
            return
          end
          if err and err ~= "" then
            logger:debug("stderr#error", "err", err)
          end
          if not err and data then
            table.insert(stderr_chunks, data)
            observer.on_stderr(data)
          end
        end),
      },
      vim.schedule_wrap(function(obj)
        if context:is_cancelled() then
          once_complete("cancelled", "")
          logger:debug("on_complete: request has been cancelled")
          return
        end
        if obj.code ~= 0 then
          local stderr_text = vim.trim(table.concat(stderr_chunks, "\n"))
          local stdout_text = vim.trim(table.concat(stdout_chunks, "\n"))
          local str = string.format(
            "process exit code: %d\nsignal: %s\nstderr:\n%s\nstdout:\n%s",
            obj.code,
            tostring(obj.signal),
            stderr_text ~= "" and stderr_text or "(empty)",
            stdout_text ~= "" and stdout_text or "(empty)"
          )
          flush_display_pending()
          if should_retry(stdout_text) then
            logger:warn(
              self:_get_provider_name() .. " run aborted before doing work",
              "attempt",
              attempts,
              "retrying",
              true
            )
            run()
            return
          end
          once_complete("failed", str)
          logger:error(
            self:_get_provider_name() .. " make_query failed",
            "error",
            str,
            "obj from results",
            obj
          )
        else
          vim.schedule(function()
            local ok, res = self:_retrieve_response(context)
            if ok and res ~= nil and vim.trim(res) ~= "" then
              once_complete("success", res)
            else
              --- fallback: some agents never write the temp file (permission
              --- denials, cwd outside the project root, or they answer in text
              --- instead).  the final text response is on stdout, so try that.
              local stdout_text = table.concat(stdout_chunks, "\n")
              local extracted = self:_extract_response(stdout_text)
              if extracted and vim.trim(extracted) ~= "" then
                logger:debug("retrieve_results: using stdout fallback")
                once_complete("success", extracted)
              elseif ok then
                once_complete(
                  "failed",
                  "no response: the agent neither wrote "
                    .. context.tmp_file
                    .. " nor produced a text response"
                )
              else
                once_complete(
                  "failed",
                  "unable to retrieve response from temp file"
                )
              end
            end
            flush_display_pending()
            if self:_get_provider_name() == "OpenCodeProvider" then
              cleanup_99_opencode_sessions(logger)
            end
          end)
        end
        if
          obj.code ~= 0 and self:_get_provider_name() == "OpenCodeProvider"
        then
          cleanup_99_opencode_sessions(logger)
        end
      end)
    )

    context:_set_process(proc)
  end

  run()
end

--- @class OpenCodeProvider : _99.Providers.BaseProvider
local OpenCodeProvider = setmetatable({}, { __index = BaseProvider })

--- @param query string
--- @param context _99.Prompt
--- @return string[]
function OpenCodeProvider._build_command(_, query, context)
  local cmd = {
    "opencode",
    "run",
  }
  local wants_no_session_persistence_disabled = not context._99
    or context._99.opencode_no_session_persistence ~= false
  local supports_no_session_persistence = true
  if context._99 then
    supports_no_session_persistence =
      OpenCodeProvider._supports_no_session_persistence()
  end
  if
    wants_no_session_persistence_disabled and supports_no_session_persistence
  then
    table.insert(cmd, "--no-session-persistence")
  end
  table.insert(cmd, "--agent")
  table.insert(cmd, "build")
  table.insert(cmd, "--title")
  table.insert(cmd, "[99.nvim]")
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
    local ok, ev = pcall(vim.json.decode, line)
    if ok then
      local text = text_from_event(ev)
      if text then
        last_text = text
      end
    end
  end
  return last_text
end

--- Map a raw stdout line to the text shown in the status area.  JSON events
--- render as their meaningful payload (text part, tool call, error message)
--- instead of the raw envelope; non-JSON lines pass through untouched so
--- plain-text providers keep working.
---
--- @param _ self
--- @param line string
--- @return string | nil
function OpenCodeProvider._stdout_line_to_display(_, line)
  local trimmed = vim.trim(line or "")
  if trimmed == "" then
    return nil
  end

  local ok, ev = pcall(vim.json.decode, line)
  if not ok or type(ev) ~= "table" then
    return trimmed
  end

  local text = text_from_event(ev)
  if text then
    return truncate_status(text)
  end

  if ev.type == "tool_use" or ev.type == "tool" then
    local part = ev.part
    if type(part) == "table" and type(part.tool) == "string" then
      return "tool: " .. part.tool
    end
    return "tool"
  end

  local err = error_from_event(ev)
  if err then
    if ev.type == "error" or ev.type == "session.error" then
      return "error: " .. truncate_status(err)
    end
  end

  --- step_start / step_finish / message / snapshot / ... carry no
  --- user-visible content worth a status row
  return nil
end

--- Ask the installed opencode whether `opencode run` accepts
--- --no-session-persistence, once per nvim session, then cache the answer.
--- Stubbed out in tests; callers that need an immediate answer while the
--- probe is in flight get the conservative `false`.
---
--- @param callback fun(supported: boolean): nil
function OpenCodeProvider._probe_no_session_persistence(callback)
  if opencode_no_session_support ~= nil then
    callback(opencode_no_session_support)
    return
  end

  if opencode_probe_started then
    pending_probe_callbacks = pending_probe_callbacks or {}
    table.insert(pending_probe_callbacks, callback)
    return
  end
  opencode_probe_started = true
  pending_probe_callbacks = { callback }

  vim.system({ "opencode", "run", "--help" }, { text = true }, function(obj)
    vim.schedule(function()
      opencode_no_session_support = obj.code == 0
        and (obj.stdout or ""):find("--no-session-persistence", 1, true)
          ~= nil
      local callbacks = pending_probe_callbacks or {}
      pending_probe_callbacks = nil
      for _, cb in ipairs(callbacks) do
        cb(opencode_no_session_support)
      end
    end)
  end)
end

--- TEST ONLY: clear the probe cache so specs can exercise both branches
function OpenCodeProvider._reset_no_session_persistence_probe()
  opencode_no_session_support = nil
  opencode_probe_started = false
  pending_probe_callbacks = nil
end

--- @return boolean
function OpenCodeProvider._supports_no_session_persistence()
  if opencode_no_session_support ~= nil then
    return opencode_no_session_support
  end
  --- kick the probe on first use; until it resolves, stay conservative
  --- (no flag), the debounced session cleanup covers that interim
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

function OpenCodeProvider.fetch_models(callback)
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

--- @class ClaudeCodeProvider : _99.Providers.BaseProvider
local ClaudeCodeProvider = setmetatable({}, { __index = BaseProvider })

--- @param query string
--- @param context _99.Prompt
--- @return string[]
function ClaudeCodeProvider._build_command(_, query, context)
  return {
    "claude",
    "--dangerously-skip-permissions",
    "--model",
    context.model,
    "--print",
    query,
  }
end

--- @return string
function ClaudeCodeProvider._get_provider_name()
  return "ClaudeCodeProvider"
end

--- @return string
function ClaudeCodeProvider._get_default_model()
  return "claude-sonnet-4-5"
end

-- TODO: the claude CLI has no way to list available models.
-- We could use the Anthropic API (https://docs.anthropic.com/en/api/models)
-- but that requires the user to have an ANTHROPIC_API_KEY set which isn't ideal.
-- Until Anthropic adds a CLI command for this, we have to hardcode the list here.
-- See https://github.com/anthropics/claude-code/issues/12612
function ClaudeCodeProvider.fetch_models(callback)
  callback({
    "claude-opus-4-6",
    "claude-sonnet-4-5",
    "claude-haiku-4-5",
    "claude-opus-4-5",
    "claude-opus-4-1",
    "claude-sonnet-4-0",
    "claude-opus-4-0",
    "claude-3-7-sonnet-latest",
  }, nil)
end

--- @class CursorAgentProvider : _99.Providers.BaseProvider
local CursorAgentProvider = setmetatable({}, { __index = BaseProvider })

--- @param query string
--- @param context _99.Prompt
--- @return string[]
function CursorAgentProvider._build_command(_, query, context)
  -- TODO: trust is sort of a hack and should probably be removed in favor of having a
  -- trust flag from the setup call
  return {
    "cursor-agent",
    "--trust", -- directories are always trusted and can be ran in
    "--force", -- allows for commands to run
    "--model",
    context.model,
    "--print",
    query,
  }
end

--- @return string
function CursorAgentProvider._get_provider_name()
  return "CursorAgentProvider"
end

--- @return string
function CursorAgentProvider._get_default_model()
  return "sonnet-4.5"
end

function CursorAgentProvider.fetch_models(callback)
  vim.system({ "cursor-agent", "models" }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, "Failed to fetch models from cursor-agent")
        return
      end
      local models = {}
      for _, line in ipairs(vim.split(obj.stdout, "\n", { trimempty = true })) do
        -- `cursor-agent models` outputs lines like "model-id - description",
        -- so we grab everything before the first " - " separator
        local id = line:match("^(%S+)%s+%-")
        if id then
          table.insert(models, id)
        end
      end
      callback(models, nil)
    end)
  end)
end

--- @class KiroProvider : _99.Providers.BaseProvider
local KiroProvider = setmetatable({}, { __index = BaseProvider })

--- @param query string
--- @param context _99.Prompt
--- @return string[]
function KiroProvider._build_command(_, query, context)
  return {
    "kiro-cli",
    "chat",
    "--no-interactive",
    "--model",
    context.model,
    "--trust-all-tools",
    query,
  }
end

--- @return string
function KiroProvider._get_provider_name()
  return "KiroProvider"
end

--- @return string
function KiroProvider._get_default_model()
  return "claude-sonnet-4.5"
end

--- @class GeminiCLIProvider : _99.Providers.BaseProvider
local GeminiCLIProvider = setmetatable({}, { __index = BaseProvider })

--- @param query string
--- @param context _99.Prompt
--- @return string[]
function GeminiCLIProvider._build_command(_, query, context)
  return {
    "gemini",
    "--approval-mode",
    -- Allow writing to temp files by default. See:
    -- https://geminicli.com/docs/core/policy-engine/#default-policies
    "auto_edit",
    "--model",
    context.model,
    "--prompt",
    query,
  }
end

--- @return string
function GeminiCLIProvider._get_provider_name()
  return "GeminiCLIProvider"
end

--- @return string
function GeminiCLIProvider._get_default_model()
  -- Default to auto-routing between pro and flash. See:
  -- https://geminicli.com/docs/cli/model/
  return "auto"
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
    local ok, ev = pcall(vim.json.decode, line)
    if ok and type(ev) == "table" then
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

  local ok, ev = pcall(vim.json.decode, line)
  if not ok or type(ev) ~= "table" then
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
      return truncate_status(ame.delta)
    end
    if
      ame.type == "text_end"
      and type(ame.content) == "string"
      and vim.trim(ame.content) ~= ""
    then
      return truncate_status(ame.content)
    end
    if
      ame.type == "thinking_delta"
      and type(ame.delta) == "string"
      and vim.trim(ame.delta) ~= ""
    then
      return "Thinking> " .. truncate_status(one_line(ame.delta))
    end
    if
      ame.type == "thinking_end"
      and type(ame.content) == "string"
      and vim.trim(ame.content) ~= ""
    then
      return "Thinking> " .. truncate_status(one_line(ame.content))
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
      return "error: " .. truncate_status(result or "")
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
      return truncate_status(text)
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

return {
  BaseProvider = BaseProvider,
  OpenCodeProvider = OpenCodeProvider,
  ClaudeCodeProvider = ClaudeCodeProvider,
  CursorAgentProvider = CursorAgentProvider,
  KiroProvider = KiroProvider,
  GeminiCLIProvider = GeminiCLIProvider,
  PiProvider = PiProvider,
}
