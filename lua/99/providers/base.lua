local utils = require("99.utils")

local once = utils.once

--- @class _99.Providers.Observer
--- @field on_stdout fun(line: string): nil raw stdout chunk, verbatim
--- @field on_stdout_line? fun(line: string): nil formatted single line for display
--- @field on_stderr fun(line: string): nil
--- @field on_complete fun(status: _99.Prompt.EndingState, res: string): nil
--- @field on_start fun(): nil

--- @class _99.Providers.BaseProvider
--- @field _build_command fun(self: _99.Providers.BaseProvider, query: string, context: _99.Prompt): string[]
--- @field _get_provider_name fun(self: _99.Providers.BaseProvider): string
--- @field _get_default_model fun(): string
local BaseProvider = {}

--- @param callback fun(models: string[]|nil, err: string|nil): nil
function BaseProvider.fetch_models(callback)
  callback(nil, "This provider does not support listing models")
end

--- @param _model string
--- @param callback fun(levels: string[]|nil, err: string|nil): nil
function BaseProvider.fetch_thinking_levels(_model, callback)
  callback(nil, "This provider does not support thinking levels")
end

--- Providers that keep track of a remote session id override this to expose
--- it for interrupt/cleanup.  Default providers have nothing to release.
---
--- @param _context _99.Prompt
--- @param _chunk string
function BaseProvider._capture_session(_, _context, _chunk) end

--- Called exactly once after a request reaches a terminal state (success,
--- failed, cancelled).  Providers use it to release remote resources such as
--- persisted sessions.
---
--- @param _context _99.Prompt
--- @param _logger _99.Logger
function BaseProvider._after_request(_, _context, _logger) end

--- Ask the provider to stop work for a request that no longer matters.  The
--- process kill stays in Prompt:cancel; providers with server-side work (the
--- opencode v2 service) override this to interrupt the session first.
---
--- @param _context _99.Prompt
--- @return boolean interrupted
function BaseProvider.interrupt(_, _context)
  return false
end

--- @param _context _99.Prompt
--- @param _stdout_text string
--- @param _attempts number
--- @return boolean
function BaseProvider._should_retry(_, _context, _stdout_text, _attempts)
  return false
end

--- @param context _99.Prompt
--- @return boolean ok
--- @return string
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

--- Extract a human-readable failure from machine output when the process
--- itself exited zero.  Providers whose protocols carry errors override it.
---
--- @param _stdout_text string
--- @return string | nil
function BaseProvider._extract_error(_, _stdout_text)
  return nil
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

--- Called before a retry attempt starts.  Providers that own remote sessions
--- release the aborted attempt's session here and clear the captured id so
--- the retry can capture its own.
---
--- @param _context _99.Prompt
--- @param _logger _99.Logger
function BaseProvider._on_retry(_, _context, _logger) end

--- @param query string
--- @param context _99.Prompt
--- @param observer _99.Providers.Observer
function BaseProvider:make_request(query, context, observer)
  observer.on_start()

  local logger = context.logger:set_area(self:_get_provider_name())
  logger:debug("make_request", "tmp_file", context.tmp_file)

  local attempts = 0

  --- every terminal path funnels through here exactly once, so remote
  --- resources are released on success, failure, and cancellation alike
  local finish = once(function(status, text)
    observer.on_complete(status, text)
    self:_after_request(context, logger)
  end)

  --- @type fun(): nil
  local run
  run = function()
    attempts = attempts + 1

    local command = self:_build_command(query, context)
    local extra_args = context._99 and context._99.provider_extra_args or {}
    utils.add_args_before_prompt(command, extra_args)
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

    --- @param data string | nil
    local function handle_stdout(data)
      logger:debug("stdout", "data", data)
      if context:is_cancelled() then
        finish("cancelled", "")
        return
      end
      if not data then
        return
      end
      table.insert(stdout_chunks, data)
      self:_capture_session(context, data)
      observer.on_stdout(data)
      if observer.on_stdout_line then
        display_pending = display_pending .. data
        local lines = vim.split(display_pending, "\n", { trimempty = false })
        display_pending = table.remove(lines) or ""
        for _, line in ipairs(lines) do
          local display = self:_stdout_line_to_display(line)
          if display then
            observer.on_stdout_line(display)
          end
        end
      end
    end

    local proc = vim.system(
      command,
      {
        text = true,
        stdout = vim.schedule_wrap(function(err, data)
          if err and err ~= "" then
            logger:debug("stdout#error", "err", err)
          end
          if not err then
            handle_stdout(data)
          end
        end),
        stderr = vim.schedule_wrap(function(err, data)
          logger:debug("stderr", "data", data)
          if context:is_cancelled() then
            finish("cancelled", "")
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
        if #stdout_chunks > 0 then
          --- authoritative re-scan: chunked pipes can cut a sessionID field
          self:_capture_session(context, table.concat(stdout_chunks, "\n"))
        end
        if context:is_cancelled() then
          finish("cancelled", "")
          logger:debug("on_complete: request has been cancelled")
          return
        end

        if obj.code ~= 0 then
          local stderr_text = vim.trim(table.concat(stderr_chunks, "\n"))
          local stdout_text = vim.trim(table.concat(stdout_chunks, "\n"))
          flush_display_pending()
          if
            attempts < 2 and self:_should_retry(context, stdout_text, attempts)
          then
            logger:warn(
              self:_get_provider_name() .. " run aborted before doing work",
              "attempt",
              attempts,
              "retrying",
              true
            )
            self:_on_retry(context, logger)
            run()
            return
          end
          local str = self:_extract_error(stdout_text)
          if not str then
            str = string.format(
              "process exit code: %d\nsignal: %s\nstderr:\n%s\nstdout:\n%s",
              obj.code,
              tostring(obj.signal),
              stderr_text ~= "" and stderr_text or "(empty)",
              stdout_text ~= "" and stdout_text or "(empty)"
            )
          end
          finish("failed", str)
          logger:error(
            self:_get_provider_name() .. " make_query failed",
            "error",
            str,
            "obj from results",
            obj
          )
          return
        end

        vim.schedule(function()
          local ok, res = self:_retrieve_response(context)
          if ok and res ~= nil and vim.trim(res) ~= "" then
            finish("success", res)
            return
          end

          --- fallback: some agents never write the temp file (permission
          --- denials, cwd outside the project root, or they answer in text
          --- instead).  the final text response is on stdout, so try that.
          local stdout_text = table.concat(stdout_chunks, "\n")
          local extracted = self:_extract_response(stdout_text)
          if extracted and vim.trim(extracted) ~= "" then
            logger:debug("retrieve_results: using stdout fallback")
            finish("success", extracted)
            return
          end

          local err = self:_extract_error(stdout_text)
          if err then
            finish("failed", err)
            return
          end

          if ok then
            finish(
              "failed",
              "no response: the agent neither wrote "
                .. context.tmp_file
                .. " nor produced a text response"
            )
          else
            finish("failed", "unable to retrieve response from temp file")
          end
        end)
        flush_display_pending()
      end)
    )

    context:_set_process(proc)
  end

  run()
end

return BaseProvider
