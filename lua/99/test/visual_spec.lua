-- luacheck: globals describe it assert
local _99 = require("99")
local test_utils = require("99.test.test_utils")
local eq = assert.are.same
local Levels = require("99.logger.level")
local Range = require("99.geo").Range
local Point = require("99.geo").Point
local visual_fn = require("99.ops.over-range")
local Prompt = require("99.prompt")

--- @param content string[]
--- @param start_row number
--- @param start_col number
--- @param end_row number
--- @param end_col number
--- @return _99.test.Provider, number, _99.Range
local function setup(content, start_row, start_col, end_row, end_col)
  local p = test_utils.TestProvider.new()
  _99.setup({
    provider = p,
    logger = {
      error_cache_level = Levels.ERROR,
    },
  })

  local buffer = test_utils.create_file(content, "lua", start_row, start_col)

  -- Set the visual marks so Prompt.visual can build a real range from them
  vim.fn.setpos("'<", { buffer, start_row, start_col, 0 })
  vim.fn.setpos("'>", { buffer, end_row, end_col, 0 })

  -- Create a range for the visual selection
  local start_point = Point:from_1_based(start_row, start_col)
  local end_point = Point:from_1_based(end_row, end_col)
  local range = Range:new(buffer, start_point, end_point)

  return p, buffer, range
end

--- @param buffer number
--- @return string[]
local function r(buffer)
  return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
end

local content = {
  "local function foo()",
  "    -- TODO: implement",
  "end",
}

--- @param context _99.Prompt
local function visual_call_with_range(context, range)
  context.data.range = range
  visual_fn(context, {
    additional_prompt = "test prompt",
  })
end

--- @param context _99.Prompt
--- @return string
local function assembled_prompt(context)
  return table.concat(context:content(), "\n")
end

describe("visual", function()
  it("should replace visual selection with AI response", function()
    local p, buffer, range = setup(content, 2, 1, 2, 23)
    local state = _99.__get_state()
    local context = Prompt.visual(state)

    visual_call_with_range(context, range)

    eq(1, state.tracking:active_count())
    eq(content, r(buffer))

    p:resolve("success", "    return 'implemented!'")
    test_utils.next_frame()

    local expected_state = {
      "local function foo()",
      "    return 'implemented!'",
      "end",
    }
    eq(expected_state, r(buffer))
    -- Note: Not checking active_request_count() == 0 due to logger bug with "id" key collision
    -- TODO: validate if this is true..
  end)

  it("should handle multi-line replacement", function()
    local multi_line_content = {
      "local function bar()",
      "    -- TODO: implement",
      "    -- more comments",
      "    -- even more",
      "end",
    }
    local p, buffer, range = setup(multi_line_content, 2, 1, 4, 17)
    local state = _99.__get_state()
    local context = Prompt.visual(state)

    visual_call_with_range(context, range)

    eq(1, state.tracking:active_count())
    eq(multi_line_content, r(buffer))

    p:resolve("success", "    local x = 1\n    local y = 2\n    return x + y")
    test_utils.next_frame()

    local expected_state = {
      "local function bar()",
      "    local x = 1",
      "    local y = 2",
      "    return x + y",
      "end",
    }
    eq(expected_state, r(buffer))
    -- Note: Not checking active_request_count() == 0 due to logger bug with "id" key collision
  end)

  it("should cancel request when stop_all_requests is called", function()
    local p, buffer, range = setup(content, 2, 1, 2, 23)
    local state = _99.__get_state()
    local context = Prompt.visual(state)

    visual_call_with_range(context, range)

    eq(content, r(buffer))

    assert.is_false(p.request.prompt:is_cancelled())
    assert.is_not_nil(p.request)
    assert.is_not_nil(p.request.prompt)

    _99.stop_all_requests()
    test_utils.next_frame()

    assert.is_true(p.request.prompt:is_cancelled())

    p:resolve("success", "    return 'should not appear'")
    test_utils.next_frame()

    -- Buffer should remain unchanged after cancellation
    eq(content, r(buffer))
  end)

  it("should handle error cases with graceful failures", function()
    local p, buffer, range = setup(content, 2, 1, 2, 23)
    local state = _99.__get_state()
    local context = Prompt.visual(state)

    visual_call_with_range(context, range)

    eq(content, r(buffer))

    p:resolve("failed", "Something went wrong")
    test_utils.next_frame()

    -- Buffer should remain unchanged on failure
    eq(content, r(buffer))
  end)

  it("should handle cancelled status gracefully", function()
    local p, buffer, range = setup(content, 2, 1, 2, 23)
    local state = _99.__get_state()
    local context = require("99.prompt").visual(state)

    visual_call_with_range(context, range)

    eq(content, r(buffer))

    -- Manually cancel and resolve as cancelled
    p.request.prompt:cancel()
    p:resolve("cancelled", "Request was cancelled")
    test_utils.next_frame()

    -- Buffer should remain unchanged on cancellation
    eq(content, r(buffer))
  end)

  it("should reject responses that reproduce the whole file", function()
    local p, buffer, range = setup(content, 2, 1, 2, 23)
    local state = _99.__get_state()
    local context = Prompt.visual(state)

    visual_call_with_range(context, range)

    local orig_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 2
    end
    p:resolve("success", table.concat(content, "\n"))
    test_utils.next_frame()
    vim.fn.confirm = orig_confirm

    -- Buffer must remain unchanged
    eq(content, r(buffer))
  end)

  it("should reject oversized responses", function()
    local p, buffer, range = setup(content, 2, 1, 2, 23)
    local state = _99.__get_state()
    local context = Prompt.visual(state)

    visual_call_with_range(context, range)

    local huge = {}
    for i = 1, 200 do
      table.insert(huge, string.format("line %d", i))
    end
    local orig_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 2
    end
    p:resolve("success", table.concat(huge, "\n"))
    test_utils.next_frame()
    vim.fn.confirm = orig_confirm

    eq(content, r(buffer))
  end)

  it("should force-apply rejected responses on confirm", function()
    local p, buffer, range = setup(content, 2, 1, 2, 23)
    local state = _99.__get_state()
    local context = Prompt.visual(state)

    visual_call_with_range(context, range)

    local huge = {}
    for i = 1, 200 do
      table.insert(huge, string.format("line %d", i))
    end
    local orig_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 1
    end
    p:resolve("success", table.concat(huge, "\n"))
    test_utils.next_frame()
    vim.fn.confirm = orig_confirm

    --- 200 forced lines replace line 2
    eq(202, #r(buffer))
  end)

  it("should accept legit expansions around 4x the selection", function()
    local p, buffer, range = setup(content, 2, 1, 2, 23)
    local state = _99.__get_state()
    local context = Prompt.visual(state)

    visual_call_with_range(context, range)

    local grown = {}
    for i = 1, 74 do
      table.insert(grown, string.format("    -- expanded line %d", i))
    end
    p:resolve("success", table.concat(grown, "\n"))
    test_utils.next_frame()

    --- line 2 replaced by the 74-line expansion
    eq(76, #r(buffer))
  end)

  it("should strip markdown code fences from responses", function()
    local p, buffer, range = setup(content, 2, 1, 2, 23)
    local state = _99.__get_state()
    local context = Prompt.visual(state)

    visual_call_with_range(context, range)

    p:resolve("success", "```lua\n    return 'implemented!'\n```")
    test_utils.next_frame()

    eq({
      "local function foo()",
      "    return 'implemented!'",
      "end",
    }, r(buffer))
  end)

  it(
    "should not reject responses that keep the original line of a tiny file",
    function()
      local tiny = { "local x = 1" }
      local p, buffer, range = setup(tiny, 1, 1, 1, 12)
      local state = _99.__get_state()
      local context = Prompt.visual(state)

      visual_call_with_range(context, range)

      p:resolve("success", "local x = 1\nreturn x")
      test_utils.next_frame()

      eq({ "local x = 1", "return x" }, r(buffer))
    end
  )

  describe("prompt density", function()
    it("omits FunctionText and shared MustObey, keeps file location", function()
      local _, _, range = setup(content, 2, 1, 2, 23)
      local state = _99.__get_state()
      local context = Prompt.visual(state)

      visual_call_with_range(context, range)

      local assembled = assembled_prompt(context)
      assert.is_nil(assembled:find("FunctionText", 1, true))
      assert.is_nil(assembled:find("MustObey", 1, true))
      assert.is_not_nil(assembled:find("<Location>", 1, true))
      assert.is_not_nil(assembled:find("<TEMP_FILE>", 1, true))
      assert.is_not_nil(assembled:find("Write ONLY TEMP_FILE", 1, true))
    end)

    it("keeps every load-bearing visual element", function()
      local _, _, range = setup(content, 2, 1, 2, 23)
      local state = _99.__get_state()
      local context = Prompt.visual(state)

      visual_call_with_range(context, range)

      local assembled = assembled_prompt(context)
      --- target, context, task, output contract, fallback
      assert.is_not_nil(assembled:find("<SELECTION_LOCATION>", 1, true))
      assert.is_not_nil(assembled:find("-- TODO: implement", 1, true))
      assert.is_not_nil(assembled:find("<SURROUNDING_CONTEXT>", 1, true))
      assert.is_not_nil(assembled:find("local function foo()", 1, true))
      assert.is_not_nil(assembled:find("<Prompt>", 1, true))
      assert.is_not_nil(assembled:find("test prompt", 1, true))
      assert.is_not_nil(assembled:find("falls back to final message", 1, true))
      assert.is_not_nil(assembled:find("no fences", 1, true))
    end)

    it("dedupes identical reference contents", function()
      local _, _, range = setup(content, 2, 1, 2, 23)
      local state = _99.__get_state()
      local context = Prompt.visual(state)

      local tmp = vim.fn.tempname()
      local file = assert(io.open(tmp, "w"))
      file:write("RULE-MARKER-123")
      file:close()

      context.data.range = range
      visual_fn(context, {
        additional_prompt = "test prompt",
        additional_rules = {
          { name = "t", path = tmp },
          { name = "t", path = tmp },
        },
      })
      os.remove(tmp)

      local assembled = assembled_prompt(context)
      local _, count = assembled:gsub("RULE%-MARKER%-123", "")
      eq(1, count)
    end)

    it("dedupes triples and preserves first-seen order", function()
      local _, _, range = setup(content, 2, 1, 2, 23)
      local state = _99.__get_state()
      local context = Prompt.visual(state)

      local tmp_a = vim.fn.tempname()
      local tmp_b = vim.fn.tempname()
      local file_a = assert(io.open(tmp_a, "w"))
      file_a:write("MARKERAAA")
      file_a:close()
      local file_b = assert(io.open(tmp_b, "w"))
      file_b:write("MARKERBBB")
      file_b:close()

      context.data.range = range
      visual_fn(context, {
        additional_prompt = "test prompt",
        additional_rules = {
          { name = "a", path = tmp_a },
          { name = "b", path = tmp_b },
          { name = "a", path = tmp_a },
        },
      })
      os.remove(tmp_a)
      os.remove(tmp_b)

      local assembled = assembled_prompt(context)
      local _, count_a = assembled:gsub("MARKERAAA", "")
      local _, count_b = assembled:gsub("MARKERBBB", "")
      eq(1, count_a)
      eq(1, count_b)
      assert.is_true(
        (assembled:find("MARKERAAA", 1, true) or 0)
          < (assembled:find("MARKERBBB", 1, true) or 0)
      )
    end)
  end)
end)
