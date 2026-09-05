-- luacheck: globals describe it assert before_each after_each
---@diagnostic disable: undefined-field, duplicate-set-field, need-check-nil
local eq = assert.are.same
local Providers = require("99.providers")

describe("providers", function()
  describe("OpenCodeProvider", function()
    local original_support_check

    before_each(function()
      original_support_check =
        Providers.OpenCodeProvider._supports_no_session_persistence
      Providers.OpenCodeProvider._supports_no_session_persistence = function()
        return true
      end
    end)

    after_each(function()
      Providers.OpenCodeProvider._supports_no_session_persistence =
        original_support_check
    end)

    it("builds correct command with model", function()
      local request = { model = "anthropic/claude-sonnet-4-5" }
      local cmd =
        Providers.OpenCodeProvider._build_command(nil, "test query", request)
      eq({
        "opencode",
        "run",
        "--no-session-persistence",
        "--agent",
        "build",
        "--title",
        "[99.nvim]",
        "--format",
        "json",
        "-m",
        "anthropic/claude-sonnet-4-5",
        "test query",
      }, cmd)
    end)

    it("can disable no-session-persistence", function()
      local request = {
        model = "anthropic/claude-sonnet-4-5",
        _99 = { opencode_no_session_persistence = false },
      }
      local cmd =
        Providers.OpenCodeProvider._build_command(nil, "test query", request)
      eq({
        "opencode",
        "run",
        "--agent",
        "build",
        "--title",
        "[99.nvim]",
        "--format",
        "json",
        "-m",
        "anthropic/claude-sonnet-4-5",
        "test query",
      }, cmd)
    end)

    it("skips no-session flag when opencode does not support it", function()
      Providers.OpenCodeProvider._supports_no_session_persistence = function()
        return false
      end

      local request = {
        model = "anthropic/claude-sonnet-4-5",
        _99 = { opencode_no_session_persistence = true },
      }
      local cmd =
        Providers.OpenCodeProvider._build_command(nil, "test query", request)
      eq({
        "opencode",
        "run",
        "--agent",
        "build",
        "--title",
        "[99.nvim]",
        "--format",
        "json",
        "-m",
        "anthropic/claude-sonnet-4-5",
        "test query",
      }, cmd)
    end)

    it("has correct default model", function()
      eq(
        "opencode/claude-sonnet-4-5",
        Providers.OpenCodeProvider._get_default_model()
      )
    end)

    describe("fetch_models", function()
      local original_system

      before_each(function()
        original_system = vim.system
      end)

      after_each(function()
        vim.system = original_system
      end)

      it("parses model ids from descriptive output and deduplicates", function()
        vim.system = function(_, _, cb)
          cb({
            code = 0,
            stdout = [[
opencode/claude-sonnet-4-5 - Anthropic Sonnet
opencode/gpt-5
opencode/claude-sonnet-4-5 - duplicate
]],
          })
        end

        local actual_models, actual_err
        Providers.OpenCodeProvider.fetch_models(function(models, err)
          actual_models = models
          actual_err = err
        end)
        vim.wait(100, function()
          return actual_models ~= nil or actual_err ~= nil
        end)

        eq(nil, actual_err)
        eq({ "opencode/claude-sonnet-4-5", "opencode/gpt-5" }, actual_models)
      end)
    end)
  end)

  describe("ClaudeCodeProvider", function()
    it("builds correct command with model", function()
      local request = { model = "anthropic/claude-sonnet-4-5" }
      local cmd =
        Providers.ClaudeCodeProvider._build_command(nil, "test query", request)
      eq({
        "claude",
        "--dangerously-skip-permissions",
        "--model",
        "anthropic/claude-sonnet-4-5",
        "--print",
        "test query",
      }, cmd)
    end)

    it("has correct default model", function()
      eq("claude-sonnet-4-5", Providers.ClaudeCodeProvider._get_default_model())
    end)
  end)

  describe("CursorAgentProvider", function()
    it("builds correct command with model", function()
      local request = { model = "anthropic/claude-sonnet-4-5" }
      local cmd =
        Providers.CursorAgentProvider._build_command(nil, "test query", request)
      eq({
        "cursor-agent",
        "--trust",
        "--force",
        "--model",
        "anthropic/claude-sonnet-4-5",
        "--print",
        "test query",
      }, cmd)
    end)

    it("has correct default model", function()
      eq("sonnet-4.5", Providers.CursorAgentProvider._get_default_model())
    end)
  end)

  describe("GeminiCLIProvider", function()
    it("builds correct command with model", function()
      local request = { model = "gemini-2.5-pro" }
      local cmd =
        Providers.GeminiCLIProvider._build_command(nil, "test query", request)
      eq({
        "gemini",
        "--approval-mode",
        "auto_edit",
        "--model",
        "gemini-2.5-pro",
        "--prompt",
        "test query",
      }, cmd)
    end)

    it("has correct default model", function()
      eq("auto", Providers.GeminiCLIProvider._get_default_model())
    end)
  end)

  describe("PiProvider", function()
    it("builds correct command with model", function()
      local request = { model = "inclusionai/ling-3.0-flash-fin:free" }
      local cmd =
        Providers.PiProvider._build_command(nil, "test query", request)
      eq({
        "pi",
        "--no-session",
        "--mode",
        "json",
        "--thinking",
        "max",
        "--model",
        "inclusionai/ling-3.0-flash-fin:free",
        "-p",
        "test query",
      }, cmd)
    end)

    it("uses pi_thinking from state when set", function()
      local request = {
        model = "inclusionai/ling-3.0-flash-fin:free",
        _99 = { pi_thinking = "low" },
      }
      local cmd =
        Providers.PiProvider._build_command(nil, "test query", request)
      eq({
        "pi",
        "--no-session",
        "--mode",
        "json",
        "--thinking",
        "low",
        "--model",
        "inclusionai/ling-3.0-flash-fin:free",
        "-p",
        "test query",
      }, cmd)
    end)

    it("has correct provider name", function()
      eq("PiProvider", Providers.PiProvider._get_provider_name())
    end)

    it("has correct default model", function()
      eq(
        "inclusionai/ling-3.0-flash-fin:free",
        Providers.PiProvider._get_default_model()
      )
    end)

    describe("fetch_models", function()
      local original_system

      before_each(function()
        original_system = vim.system
      end)

      after_each(function()
        vim.system = original_system
      end)

      it("parses model ids from table output and deduplicates", function()
        vim.system = function(cmd, _, cb)
          eq({ "pi", "--list-models" }, cmd)
          cb({
            code = 0,
            stdout = "provider    model                                  context  max-out\n"
              .. "openrouter  inclusionai/ling-3.0-flash-fin:free  262.1K   32.8K\n"
              .. "openrouter  ~anthropic/claude-sonnet-latest      1M       128K\n"
              .. "openrouter  inclusionai/ling-3.0-flash-fin:free  262.1K   32.8K\n",
          })
        end

        local actual_models, actual_err
        Providers.PiProvider.fetch_models(function(models, err)
          actual_models = models
          actual_err = err
        end)
        vim.wait(100, function()
          return actual_models ~= nil or actual_err ~= nil
        end)

        eq(nil, actual_err)
        eq({
          "inclusionai/ling-3.0-flash-fin:free",
          "anthropic/claude-sonnet-latest",
        }, actual_models)
      end)

      it("returns an error when listing fails", function()
        vim.system = function(_, _, cb)
          cb({ code = 1, stdout = "", stderr = "boom" })
        end

        local actual_models, actual_err
        Providers.PiProvider.fetch_models(function(models, err)
          actual_models = models
          actual_err = err
        end)
        vim.wait(100, function()
          return actual_models ~= nil or actual_err ~= nil
        end)

        eq(nil, actual_models)
        eq("Failed to fetch models from pi", actual_err)
      end)
    end)

    describe("_extract_response", function()
      it("takes the last assistant message_end text", function()
        local stdout = table.concat({
          '{"type":"session","version":3,"id":"s1"}',
          '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"first draft"}]}}',
          '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"  final answer  "}]}}',
        }, "\n")

        eq(
          "  final answer  ",
          Providers.PiProvider._extract_response(nil, stdout)
        )
      end)

      it(
        "falls back to agent_end messages when no message_end exists",
        function()
          local stdout = table.concat({
            '{"type":"agent_end","messages":[{"role":"user","content":[{"type":"text","text":"hi"}]},'
              .. '{"role":"assistant","content":[{"type":"text","text":"agent answer"}]}]}',
          }, "\n")

          eq(
            "agent answer",
            Providers.PiProvider._extract_response(nil, stdout)
          )
        end
      )

      it("falls back to streaming text_end content", function()
        local stdout = table.concat({
          '{"type":"message_update","usage":{},"assistantMessageEvent":'
            .. '{"type":"text_end","contentIndex":0,"content":"streamed answer"}}',
        }, "\n")

        eq(
          "streamed answer",
          Providers.PiProvider._extract_response(nil, stdout)
        )
      end)

      it("ignores user messages and tool events", function()
        local stdout = table.concat({
          '{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"user text"}]}}',
          '{"type":"tool_execution_start","toolCallId":"1","toolName":"read","args":{}}',
          '{"type":"tool_execution_end","toolCallId":"1","toolName":"read","result":{},"isError":false}',
        }, "\n")

        eq(nil, Providers.PiProvider._extract_response(nil, stdout))
      end)

      it("ignores thinking content in assistant messages", function()
        local stdout = table.concat({
          '{"type":"message_end","message":{"role":"assistant","content":['
            .. '{"type":"thinking","thinking":"hmm"},'
            .. '{"type":"text","text":"real answer"}]}}',
        }, "\n")

        eq("real answer", Providers.PiProvider._extract_response(nil, stdout))
      end)

      it("returns nil when only thinking content exists", function()
        local stdout = table.concat({
          '{"type":"message_end","message":{"role":"assistant","content":['
            .. '{"type":"thinking","thinking":"hmm"}]}}',
        }, "\n")

        eq(nil, Providers.PiProvider._extract_response(nil, stdout))
      end)

      it("returns nil for empty or nil stdout", function()
        eq(nil, Providers.PiProvider._extract_response(nil, ""))
        eq(nil, Providers.PiProvider._extract_response(nil, nil))
      end)
    end)

    describe("_stdout_line_to_display", function()
      it("renders text deltas as their payload", function()
        eq(
          "hello there",
          Providers.PiProvider._stdout_line_to_display(
            nil,
            '{"type":"message_update","usage":{},"assistantMessageEvent":'
              .. '{"type":"text_delta","contentIndex":0,"delta":"hello there"}}'
          )
        )
      end)

      it("renders tool_execution_start as a tool line", function()
        eq(
          "tool: read",
          Providers.PiProvider._stdout_line_to_display(
            nil,
            '{"type":"tool_execution_start","toolCallId":"1","toolName":"read","args":{}}'
          )
        )
      end)

      it("renders toolcall_start as a tool line", function()
        eq(
          "tool: bash",
          Providers.PiProvider._stdout_line_to_display(
            nil,
            '{"type":"message_update","usage":{},"assistantMessageEvent":'
              .. '{"type":"toolcall_start","id":"1","toolName":"bash"}}'
          )
        )
      end)

      it("hides streaming thinking deltas", function()
        eq(
          nil,
          Providers.PiProvider._stdout_line_to_display(
            nil,
            '{"type":"message_update","usage":{},"assistantMessageEvent":'
              .. '{"type":"thinking_delta","contentIndex":0,'
              .. '"delta":"weighing options"}}'
          )
        )
      end)

      it("renders thinking_end content under a Thinking marker", function()
        eq(
          "Thinking> settled",
          Providers.PiProvider._stdout_line_to_display(
            nil,
            '{"type":"message_update","usage":{},"assistantMessageEvent":'
              .. '{"type":"thinking_end","contentIndex":0,'
              .. '"content":"settled"}}'
          )
        )
      end)

      it("collapses newlines in thinking payloads", function()
        eq(
          "Thinking> line one line two",
          Providers.PiProvider._stdout_line_to_display(
            nil,
            '{"type":"message_update","usage":{},"assistantMessageEvent":'
              .. '{"type":"thinking_end","contentIndex":0,'
              .. '"content":"line one\\nline two"}}'
          )
        )
      end)

      it("hides thinking_start envelopes", function()
        eq(
          nil,
          Providers.PiProvider._stdout_line_to_display(
            nil,
            '{"type":"message_update","usage":{},"assistantMessageEvent":'
              .. '{"type":"thinking_start","contentIndex":0}}'
          )
        )
      end)

      it("truncates long thinking payloads", function()
        local long = string.rep("b", 500)
        local out = Providers.PiProvider._stdout_line_to_display(
          nil,
          '{"type":"message_update","usage":{},"assistantMessageEvent":'
            .. '{"type":"thinking_end","contentIndex":0,"content":"'
            .. long
            .. '"}}'
        )
        assert.is_true(out ~= nil)
        eq("Thinking> " .. string.rep("b", 160) .. " …", out)
      end)

      it("renders failed tool executions with their result", function()
        eq(
          "error: denied",
          Providers.PiProvider._stdout_line_to_display(
            nil,
            '{"type":"tool_execution_end","toolCallId":"1","toolName":"bash","result":"denied","isError":true}'
          )
        )
      end)

      it("hides successful tool executions", function()
        eq(
          nil,
          Providers.PiProvider._stdout_line_to_display(
            nil,
            '{"type":"tool_execution_end","toolCallId":"1","toolName":"read","result":{},"isError":false}'
          )
        )
      end)

      it("renders final assistant messages as their text", function()
        eq(
          "done",
          Providers.PiProvider._stdout_line_to_display(
            nil,
            '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}'
          )
        )
      end)

      it("hides lifecycle envelopes", function()
        eq(
          nil,
          Providers.PiProvider._stdout_line_to_display(
            nil,
            '{"type":"session","version":3,"id":"s1"}'
          )
        )
        eq(
          nil,
          Providers.PiProvider._stdout_line_to_display(
            nil,
            '{"type":"turn_start"}'
          )
        )
        eq(
          nil,
          Providers.PiProvider._stdout_line_to_display(
            nil,
            '{"type":"message_start","message":{"role":"assistant","content":[]}}'
          )
        )
      end)

      it("passes non-json lines through untouched", function()
        eq(
          "plain text line",
          Providers.PiProvider._stdout_line_to_display(
            nil,
            "  plain text line  "
          )
        )
      end)

      it("hides blank lines", function()
        eq(nil, Providers.PiProvider._stdout_line_to_display(nil, ""))
        eq(nil, Providers.PiProvider._stdout_line_to_display(nil, "   "))
      end)

      it("truncates long text payloads", function()
        local long = string.rep("a", 500)
        local out = Providers.PiProvider._stdout_line_to_display(
          nil,
          '{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"'
            .. long
            .. '"}}'
        )
        assert.is_true(out ~= nil)
        assert.is_true(#out < #long)
        eq(string.rep("a", 160) .. " …", out)
      end)
    end)

    describe("make_request", function()
      local original_system

      before_each(function()
        original_system = vim.system
      end)

      after_each(function()
        vim.system = original_system
      end)

      it("does not retry generic failures", function()
        local calls = 0
        local done = false
        local results = {}
        vim.system = function(cmd, opts, cb)
          eq("pi", cmd[1])
          calls = calls + 1
          if opts.stdout then
            opts.stdout(nil, "boom")
          end
          cb({ code = 1, signal = 0, stdout = "boom", stderr = "" })
        end

        local tmp = vim.fn.tempname()
        local logger = require("99.logger.logger"):set_id(1234)
        logger.level = require("99.logger.level").FATAL
        local context = {
          logger = logger,
          tmp_file = tmp,
          _99 = nil,
          is_cancelled = function()
            return false
          end,
          _set_process = function() end,
        }
        Providers.PiProvider:make_request("q", context, {
          on_start = function() end,
          on_complete = function(status, res)
            done = true
            table.insert(results, { status, res })
          end,
          on_stdout = function() end,
          on_stderr = function() end,
        })
        vim.wait(2000, function()
          return done
        end)

        eq(1, calls)
        eq(1, #results)
        eq("failed", results[1][1])
      end)

      it(
        "renders clean display lines when chunks split json events mid-line",
        function()
          local done = false
          local display_lines = {}
          vim.system = function(_, opts, cb)
            local fragments = {
              '{"type":"session","version":3,"id":"s1"}\n'
                .. '{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"te',
              'xt_delta","contentIndex":0,"delta":"thinking out loud..."}}\n'
                .. '{"type":"tool_execution_start","toolCallId":"1","toolName":"bash","args":{}}',
              '\n{"type":"message_end","message":{"role":"assistant",'
                .. '"content":[{"type":"text","text":"the answer"}]}}\n',
            }
            for i = 1, #fragments do
              if opts.stdout and fragments[i] then
                opts.stdout(nil, fragments[i])
              end
            end
            cb({ code = 0, signal = 0, stdout = "", stderr = "" })
          end

          local tmp = vim.fn.tempname()
          local logger = require("99.logger.logger"):set_id(1234)
          logger.level = require("99.logger.level").FATAL
          local context = {
            logger = logger,
            tmp_file = tmp,
            _99 = nil,
            is_cancelled = function()
              return false
            end,
            _set_process = function() end,
          }
          Providers.PiProvider:make_request("q", context, {
            on_start = function() end,
            on_complete = function()
              done = true
            end,
            on_stdout = function() end,
            on_stdout_line = function(line)
              table.insert(display_lines, line)
            end,
            on_stderr = function() end,
          })
          vim.wait(2000, function()
            return done
          end)

          eq(
            { "thinking out loud...", "tool: bash", "the answer" },
            display_lines
          )
          for _, line in ipairs(display_lines) do
            assert.is_nil(line:find('{"', 1, true))
          end
        end
      )
    end)
  end)

  describe("provider integration", function()
    it("can be set as provider override", function()
      local _99 = require("99")

      _99.setup({ provider = Providers.ClaudeCodeProvider })
      local state = _99.__get_state()
      eq(Providers.ClaudeCodeProvider, state.provider_override)
    end)

    it(
      "uses OpenCodeProvider default model when no provider or model specified",
      function()
        local _99 = require("99")

        _99.setup({})
        local state = _99.__get_state()
        eq("opencode/claude-sonnet-4-5", state.model)
      end
    )

    it(
      "uses ClaudeCodeProvider default model when provider specified but no model",
      function()
        local _99 = require("99")

        _99.setup({ provider = Providers.ClaudeCodeProvider })
        local state = _99.__get_state()
        eq("claude-sonnet-4-5", state.model)
      end
    )

    it(
      "uses CursorAgentProvider default model when provider specified but no model",
      function()
        local _99 = require("99")

        _99.setup({ provider = Providers.CursorAgentProvider })
        local state = _99.__get_state()
        eq("sonnet-4.5", state.model)
      end
    )

    it(
      "uses GeminiCLIProvider default model when provider specified but no model",
      function()
        local _99 = require("99")

        _99.setup({ provider = Providers.GeminiCLIProvider })
        local state = _99.__get_state()
        eq("auto", state.model)
      end
    )

    it(
      "uses PiProvider default model when provider specified but no model",
      function()
        local _99 = require("99")

        _99.setup({ provider = Providers.PiProvider })
        local state = _99.__get_state()
        eq("inclusionai/ling-3.0-flash-fin:free", state.model)
      end
    )

    it("defaults pi_thinking to max", function()
      local _99 = require("99")

      _99.setup({})
      local state = _99.__get_state()
      eq("max", state.pi_thinking)
    end)

    it("accepts a custom pi_thinking level", function()
      local _99 = require("99")

      _99.setup({ pi_thinking = "low" })
      local state = _99.__get_state()
      eq("low", state.pi_thinking)
    end)

    it("rejects an unknown pi_thinking level", function()
      local _99 = require("99")

      local ok = pcall(_99.setup, { pi_thinking = "ultra" })
      eq(false, ok)
    end)

    it("sets and gets thinking level at runtime", function()
      local _99 = require("99")

      _99.setup({ provider = Providers.PiProvider })
      eq("max", _99.get_thinking())
      _99.set_thinking("low")
      eq("low", _99.get_thinking())
      local state = _99.__get_state()
      eq("low", state.pi_thinking)
    end)

    it("rejects an unknown thinking level at runtime", function()
      local _99 = require("99")

      _99.setup({ provider = Providers.PiProvider })
      local ok = pcall(_99.set_thinking, "ultra")
      eq(false, ok)
      eq("max", _99.get_thinking())
    end)

    describe("thinking picker", function()
      local catalog_path

      before_each(function()
        catalog_path = vim.fn.tempname()
        Providers.PiProvider._catalog_path_override = catalog_path
        local file = assert(io.open(catalog_path, "w"))
        file:write(vim.json.encode({
          openrouter = {
            models = {
              {
                id = "z-ai/glm-5.3-flash",
                reasoning = true,
                thinkingLevelMap = {
                  off = vim.NIL,
                  minimal = vim.NIL,
                  low = "low",
                  medium = vim.NIL,
                  high = "high",
                  xhigh = vim.NIL,
                  max = "max",
                },
              },
            },
          },
        }))
        file:close()
      end)

      after_each(function()
        Providers.PiProvider._catalog_path_override = nil
        os.remove(catalog_path)
      end)

      it("lists supported levels for the current model", function()
        local _99 = require("99")
        local pickers_util = require("99.extensions.pickers")

        _99.setup({
          provider = Providers.PiProvider,
          model = "z-ai/glm-5.3-flash",
          pi_thinking = "max",
        })

        local levels, current
        pickers_util.get_thinking_levels(nil, nil, function(l, c)
          levels = l
          current = c
        end)
        eq("max", current)
        eq({ "low", "high", "max" }, levels)
      end)

      it("prepends current level when the model lacks it", function()
        local _99 = require("99")
        local pickers_util = require("99.extensions.pickers")

        _99.setup({
          provider = Providers.PiProvider,
          model = "z-ai/glm-5.3-flash",
          pi_thinking = "medium",
        })

        local levels, current
        pickers_util.get_thinking_levels(nil, nil, function(l, c)
          levels = l
          current = c
        end)
        eq("medium", current)
        eq({ "medium", "low", "high", "max" }, levels)
      end)

      it("selecting a level updates state", function()
        local _99 = require("99")
        local pickers_util = require("99.extensions.pickers")

        _99.setup({ provider = Providers.PiProvider })
        pickers_util.on_thinking_selected("low")
        eq("low", _99.get_thinking())
      end)
    end)

    it("uses custom model when both provider and model specified", function()
      local _99 = require("99")

      _99.setup({
        provider = Providers.ClaudeCodeProvider,
        model = "custom-model",
      })
      local state = _99.__get_state()
      eq("custom-model", state.model)
    end)
  end)

  describe("provider_extra_args", function()
    it("stores provider_extra_args on state", function()
      local _99 = require("99")
      _99.setup({
        provider_extra_args = { "--no-session-persistence" },
      })
      local state = _99.__get_state()
      eq({ "--no-session-persistence" }, state.provider_extra_args)
    end)

    it("defaults provider_extra_args to empty table", function()
      local _99 = require("99")
      _99.setup({})
      local state = _99.__get_state()
      eq({}, state.provider_extra_args)
    end)
  end)

  describe("opencode session persistence option", function()
    it("defaults to no-session-persistence enabled", function()
      local _99 = require("99")
      _99.setup({})
      local state = _99.__get_state()
      eq(true, state.opencode_no_session_persistence)
    end)

    it("can be disabled via setup option", function()
      local _99 = require("99")
      _99.setup({
        opencode_no_session_persistence = false,
      })
      local state = _99.__get_state()
      eq(false, state.opencode_no_session_persistence)
    end)
  end)

  describe("fetch_thinking_levels", function()
    local catalog_path

    before_each(function()
      catalog_path = vim.fn.tempname()
      Providers.PiProvider._catalog_path_override = catalog_path
    end)

    after_each(function()
      Providers.PiProvider._catalog_path_override = nil
      os.remove(catalog_path)
    end)

    --- @param store table
    local function write_catalog(store)
      local file = assert(io.open(catalog_path, "w"))
      file:write(vim.json.encode(store))
      file:close()
    end

    --- @param model string
    --- @return string[]|nil, string|nil
    local function fetch(model)
      local levels, err
      Providers.PiProvider.fetch_thinking_levels(model, function(l, e)
        levels = l
        err = e
      end)
      return levels, err
    end

    it("returns mapped levels for an exact id match", function()
      write_catalog({
        openrouter = {
          models = {
            {
              id = "z-ai/glm-5.3-flash",
              reasoning = true,
              thinkingLevelMap = {
                off = vim.NIL,
                minimal = vim.NIL,
                low = "low",
                medium = vim.NIL,
                high = "high",
                xhigh = vim.NIL,
                max = "max",
              },
            },
          },
        },
      })

      local levels, err = fetch("z-ai/glm-5.3-flash")
      eq(nil, err)
      eq({ "low", "high", "max" }, levels)
    end)

    it("returns standard levels when the map is absent", function()
      write_catalog({
        openrouter = {
          models = {
            {
              id = "inclusionai/ling-3.0-flash-fin:free",
              reasoning = true,
            },
          },
        },
      })

      local levels, err = fetch("inclusionai/ling-3.0-flash-fin:free")
      eq(nil, err)
      eq({ "off", "minimal", "low", "medium", "high" }, levels)
    end)

    it(
      "excludes null entries but keeps extended levels unmapped out",
      function()
        write_catalog({
          openrouter = {
            models = {
              {
                id = "aion",
                reasoning = true,
                thinkingLevelMap = { off = vim.NIL },
              },
            },
          },
        })

        local levels, err = fetch("aion")
        eq(nil, err)
        eq({ "minimal", "low", "medium", "high" }, levels)
      end
    )

    it("returns off only for non-reasoning models", function()
      write_catalog({
        openrouter = {
          models = {
            { id = "plain", reasoning = false },
          },
        },
      })

      local levels, err = fetch("plain")
      eq(nil, err)
      eq({ "off" }, levels)
    end)

    it("matches ids with a provider prefix stripped", function()
      write_catalog({
        openrouter = {
          models = {
            {
              id = "z-ai/glm-5.3-flash",
              reasoning = true,
              thinkingLevelMap = {
                off = vim.NIL,
                minimal = vim.NIL,
                low = "low",
                medium = vim.NIL,
                high = "high",
                xhigh = vim.NIL,
                max = "max",
              },
            },
          },
        },
      })

      local levels, err = fetch("openrouter/z-ai/glm-5.3-flash")
      eq(nil, err)
      eq({ "low", "high", "max" }, levels)
    end)

    it("falls back to all levels for unknown models", function()
      write_catalog({ openrouter = { models = {} } })

      local levels, err = fetch("nope")
      eq(nil, err)
      eq({ "off", "minimal", "low", "medium", "high", "xhigh", "max" }, levels)
    end)

    it("falls back to all levels when the catalog is missing", function()
      os.remove(catalog_path)

      local levels, err = fetch("anything")
      eq(nil, err)
      eq({ "off", "minimal", "low", "medium", "high", "xhigh", "max" }, levels)
    end)

    it("falls back to all levels on invalid JSON", function()
      local file = assert(io.open(catalog_path, "w"))
      file:write("not json {{{")
      file:close()

      local levels, err = fetch("anything")
      eq(nil, err)
      eq({ "off", "minimal", "low", "medium", "high", "xhigh", "max" }, levels)
    end)
  end)

  describe("BaseProvider thinking levels", function()
    it("reports unsupported", function()
      local levels, err
      Providers.BaseProvider.fetch_thinking_levels("m", function(l, e)
        levels = l
        err = e
      end)
      eq(nil, levels)
      eq("This provider does not support thinking levels", err)
    end)
  end)

  describe("BaseProvider", function()
    it("all providers have make_request", function()
      eq("function", type(Providers.OpenCodeProvider.make_request))
      eq("function", type(Providers.ClaudeCodeProvider.make_request))
      eq("function", type(Providers.CursorAgentProvider.make_request))
      eq("function", type(Providers.GeminiCLIProvider.make_request))
      eq("function", type(Providers.PiProvider.make_request))
    end)
  end)

  describe("_extract_response", function()
    it(
      "parses the last completed text part from opencode json events",
      function()
        local stdout = table.concat({
          '{"type":"step_start","timestamp":1,"sessionID":"s1","part":{"type":"step-start"}}',
          '{"type":"tool_use","timestamp":2,"sessionID":"s1","part":{"type":"tool",'
            .. '"tool":"bash","state":{"status":"completed"}}}',
          '{"type":"text","timestamp":3,"sessionID":"s1","part":{"type":"text",'
            .. '"text":"first draft","time":{"end":123}}}',
          '{"type":"text","timestamp":4,"sessionID":"s1","part":{"type":"text",'
            .. '"text":"  final answer  ","time":{"end":124}}}',
        }, "\n")

        eq(
          "  final answer  ",
          Providers.OpenCodeProvider._extract_response(nil, stdout)
        )
      end
    )

    it("returns nil when there is no completed text part", function()
      local stdout = table.concat({
        '{"type":"tool_use","timestamp":1,"sessionID":"s1","part":{"type":"tool","tool":"bash"}}',
        '{"type":"session.error","timestamp":2,"sessionID":"s1","error":{}}',
      }, "\n")

      eq(nil, Providers.OpenCodeProvider._extract_response(nil, stdout))
    end)

    it("returns nil for empty or nil stdout", function()
      eq(nil, Providers.OpenCodeProvider._extract_response(nil, ""))
      eq(nil, Providers.OpenCodeProvider._extract_response(nil, nil))
    end)

    it("default provider returns trimmed stdout", function()
      eq("hello", Providers.BaseProvider:_extract_response("  hello  "))
      eq(nil, Providers.BaseProvider:_extract_response("   "))
    end)

    it(
      "extracts text from message.part.updated events (newer stream shapes)",
      function()
        local stdout = table.concat({
          '{"type":"message.part.updated","part":{"type":"text","text":"draft"}}',
          '{"type":"message.part.updated","part":{"type":"text","text":"final answer"}}',
        }, "\n")
        eq(
          "final answer",
          Providers.OpenCodeProvider._extract_response(nil, stdout)
        )
      end
    )

    it("still returns nil when only step/tool/error events exist", function()
      local stdout = table.concat({
        '{"type":"step_start","part":{"type":"step-start"}}',
        '{"type":"error","error":{"data":{"message":"Failed query"}}}',
      }, "\n")
      eq(nil, Providers.OpenCodeProvider._extract_response(nil, stdout))
    end)
  end)

  describe("_stdout_line_to_display", function()
    it("hides step_start envelopes", function()
      eq(
        nil,
        Providers.OpenCodeProvider._stdout_line_to_display(
          nil,
          '{"type":"step_start","timestamp":1,"sessionID":"s1","part":{"type":"step-start"}}'
        )
      )
    end)

    it("renders text parts as their payload", function()
      eq(
        "hello there",
        Providers.OpenCodeProvider._stdout_line_to_display(
          nil,
          '{"type":"text","timestamp":1,"sessionID":"s1","part":{"type":"text","text":"hello there"}}'
        )
      )
    end)

    it("renders message.part.updated text too", function()
      eq(
        "live text",
        Providers.OpenCodeProvider._stdout_line_to_display(
          nil,
          '{"type":"message.part.updated","part":{"type":"text","text":"live text"}}'
        )
      )
    end)

    it("renders tool_use as a tool line", function()
      eq(
        "tool: bash",
        Providers.OpenCodeProvider._stdout_line_to_display(
          nil,
          '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"running"}}}'
        )
      )
    end)

    it("renders error events with their message", function()
      eq(
        "error: Unexpected server error. Check server logs for details.",
        Providers.OpenCodeProvider._stdout_line_to_display(
          nil,
          '{"type":"error","error":{"name":"UnknownError","data":{"message":'
            .. '"Unexpected server error. Check server logs for details.",'
            .. '"ref":"err_37aeaf83"}}}'
        )
      )
    end)

    it("renders session.error only when it carries a message", function()
      eq(
        nil,
        Providers.OpenCodeProvider._stdout_line_to_display(
          nil,
          '{"type":"session.error","error":{}}'
        )
      )
      eq(
        "error: boom",
        Providers.OpenCodeProvider._stdout_line_to_display(
          nil,
          '{"type":"session.error","error":{"message":"boom"}}'
        )
      )
    end)

    it("passes non-json lines through untouched", function()
      eq(
        "plain text line",
        Providers.OpenCodeProvider._stdout_line_to_display(
          nil,
          "  plain text line  "
        )
      )
    end)

    it("hides blank lines", function()
      eq(nil, Providers.OpenCodeProvider._stdout_line_to_display(nil, ""))
      eq(nil, Providers.OpenCodeProvider._stdout_line_to_display(nil, "   "))
    end)

    it("truncates long text parts", function()
      local long = string.rep("a", 500)
      local out = Providers.OpenCodeProvider._stdout_line_to_display(
        nil,
        '{"type":"text","part":{"type":"text","text":"' .. long .. '"}}'
      )
      assert.is_true(out ~= nil)
      assert.is_true(#out < #long)
      eq(string.rep("a", 160) .. " …", out)
    end)
  end)

  describe("no-session-persistence probe", function()
    local original_system

    before_each(function()
      original_system = vim.system
      Providers.OpenCodeProvider._reset_no_session_persistence_probe()
    end)

    after_each(function()
      vim.system = original_system
      Providers.OpenCodeProvider._reset_no_session_persistence_probe()
    end)

    it("caches true when opencode run --help lists the flag", function()
      local received
      vim.system = function(cmd, _, cb)
        eq("opencode", cmd[1])
        eq("run", cmd[2])
        cb({
          code = 0,
          stdout = "opencode run [options]\n  --no-session-persistence   do not persist the session\n",
          stderr = "",
        })
      end

      Providers.OpenCodeProvider._probe_no_session_persistence(
        function(supported)
          received = supported
        end
      )
      vim.wait(2000, function()
        return received ~= nil
      end)
      eq(true, received)

      --- cached: a second call resolves immediately with the same answer
      local second
      Providers.OpenCodeProvider._probe_no_session_persistence(
        function(supported)
          second = supported
        end
      )
      eq(true, second)
    end)

    it("caches false when the flag is absent", function()
      local received
      vim.system = function(_, _, cb)
        cb({
          code = 0,
          stdout = "opencode run [options]\n  --agent <name>\n",
          stderr = "",
        })
      end

      Providers.OpenCodeProvider._probe_no_session_persistence(
        function(supported)
          received = supported
        end
      )
      vim.wait(2000, function()
        return received ~= nil
      end)
      eq(false, received)
    end)

    it("caches false when the help command fails", function()
      local received
      vim.system = function(_, _, cb)
        cb({ code = 1, stdout = "", stderr = "" })
      end

      Providers.OpenCodeProvider._probe_no_session_persistence(
        function(supported)
          received = supported
        end
      )
      vim.wait(2000, function()
        return received ~= nil
      end)
      eq(false, received)
    end)
  end)

  describe("make_request retry", function()
    local original_system
    local original_support

    before_each(function()
      original_system = vim.system
      original_support =
        Providers.OpenCodeProvider._supports_no_session_persistence
      --- keep _build_command from running the real probe against opencode
      Providers.OpenCodeProvider._supports_no_session_persistence = function()
        return false
      end
    end)

    after_each(function()
      vim.system = original_system
      Providers.OpenCodeProvider._supports_no_session_persistence =
        original_support
    end)

    --- drives make_request against stubbed opencode runs.  branches[key]
    --- is the response of the (key)-th `opencode run` invocation.
    ---
    --- @param branches table<number, {code: number, stdout: string}>
    --- @return table
    local function run_request(branches)
      local calls = 0
      local done = false
      local results = {}
      local display_lines = {}
      vim.system = function(cmd, opts, cb)
        if cmd[1] == "opencode" and cmd[2] == "session" then
          --- session cleanup from the request completion
          cb({ code = 0, stdout = "", stderr = "" })
          return
        end
        calls = calls + 1
        local branch = branches[calls]
        --- feed stdout either as one chunk or as fragmented chunks that
        --- split json events mid-line, like real process pipes do
        local fragments = branch.fragments or { branch.stdout }
        for i = 1, #fragments do
          if opts.stdout and fragments[i] then
            opts.stdout(nil, fragments[i])
          end
        end
        cb({
          code = branch.code,
          signal = 0,
          stdout = branch.stdout or "",
          stderr = branch.stderr or "",
        })
      end

      local tmp = vim.fn.tempname()
      local f = io.open(tmp, "w")
      if f then
        f:close()
      end

      --- FATAL so debug/warn lines never hit the logger's arg-count assert
      local logger = require("99.logger.logger"):set_id(1234)
      logger.level = require("99.logger.level").FATAL
      local context = {
        logger = logger,
        tmp_file = tmp,
        _99 = nil,
        is_cancelled = function()
          return false
        end,
        _set_process = function() end,
      }
      local observer = {
        on_start = function() end,
        on_complete = function(status, res)
          done = true
          table.insert(results, { status, res })
        end,
        on_stdout = function() end,
        on_stdout_line = function(line)
          table.insert(display_lines, line)
        end,
        on_stderr = function() end,
      }
      return {
        calls = function()
          return calls
        end,
        results = results,
        display = display_lines,
        context = context,
        observer = observer,
        wait = function()
          vim.wait(2000, function()
            return done
          end)
        end,
      }
    end

    it(
      "retries once when opencode dies at step start with a persistence error",
      function()
        local r = run_request({
          {
            code = 1,
            stdout = '{"type":"error","error":{"name":"UnknownError","data":{"message":'
              .. '"Failed query: insert into \\"part\\" values (...)",'
              .. '"ref":"err_1"}}}',
          },
          {
            code = 0,
            stdout = '{"type":"text","part":{"type":"text","text":"the answer"}}',
          },
        })

        Providers.OpenCodeProvider:make_request("q", r.context, r.observer)
        r.wait()

        eq(2, r.calls())
        eq(1, #r.results)
        eq("success", r.results[1][1])
        eq("the answer", r.results[1][2])
      end
    )

    it(
      "does not retry when the agent had already started (tool_use seen)",
      function()
        local r = run_request({
          {
            code = 1,
            stdout = '{"type":"tool_use","part":{"type":"tool","tool":"bash"}}'
              .. '\n{"type":"error","error":{"data":{"message":"Failed query"}}}',
          },
        })

        Providers.OpenCodeProvider:make_request("q", r.context, r.observer)
        r.wait()

        eq(1, r.calls())
        eq(1, #r.results)
        eq("failed", r.results[1][1])
      end
    )

    it("does not retry generic failures", function()
      local r = run_request({
        { code = 1, stdout = "boom" },
      })

      Providers.OpenCodeProvider:make_request("q", r.context, r.observer)
      r.wait()

      eq(1, r.calls())
      eq(1, #r.results)
      eq("failed", r.results[1][1])
    end)

    it(
      "renders clean display lines when chunks split json events mid-line",
      function()
        local r = run_request({
          {
            code = 0,
            --- chunk boundaries cut through events on purpose: only whole,
            --- formatted lines may reach the status area
            fragments = {
              '{"type":"step_start","part":{"type":"step-start"}}\n'
                .. '{"type":"message.part.updated","part":{"type":"te',
              'xt","text":"thinking out loud..."}}\n'
                .. '{"type":"tool_use","part":{"type":"tool","tool":"bash"}}',
              '\n{"type":"text","part":{"type":"text","text":"the answer"}}\n',
            },
          },
        })

        Providers.OpenCodeProvider:make_request("q", r.context, r.observer)
        r.wait()

        eq({ "thinking out loud...", "tool: bash", "the answer" }, r.display)
        --- no raw json envelope fragments ever reach the display
        for _, line in ipairs(r.display) do
          assert.is_nil(line:find('{"', 1, true))
        end
        eq("success", r.results[1][1])
        eq("the answer", r.results[1][2])
      end
    )
  end)
end)
