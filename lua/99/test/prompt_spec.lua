-- luacheck: globals describe it assert
---@diagnostic disable: undefined-field, duplicate-set-field
local _99 = require("99")
local test_utils = require("99.test.test_utils")
local Prompt = require("99.prompt")
local eq = assert.are.same

describe("prompt", function()
  it("should deserialize a serialized prompt", function()
    local provider = test_utils.TestProvider.new()
    _99.setup(test_utils.get_test_setup_options({}, provider))

    local state = _99.__get_state()
    local prompt = Prompt.deserialize(state, {
      user_prompt = "find important changes",
      data = {
        type = "search",
        qfix_items = {},
        response = "",
      },
    })

    eq("search", prompt.operation)
    eq("search", prompt.data.type)
    eq("find important changes", prompt.user_prompt)
    eq("search: find important changes", prompt:summary())
  end)

  describe("finalize output discipline", function()
    --- @return string
    local function finalized(operation)
      local provider = test_utils.TestProvider.new()
      _99.setup(test_utils.get_test_setup_options({}, provider))
      test_utils.create_file({ "hello" }, "lua", 1, 0)

      local state = _99.__get_state()
      local context = Prompt[operation](state)
      assert.is_not_nil(context)
      context:finalize()
      return table.concat(context:content(), "\n")
    end

    it("keeps shared MustObey for tutorial and search", function()
      assert.is_not_nil(finalized("tutorial"):find("MustObey", 1, true))
      assert.is_not_nil(finalized("search"):find("MustObey", 1, true))
    end)

    it("leaves vibe discipline to its own template", function()
      assert.is_nil(finalized("vibe"):find("MustObey", 1, true))
    end)
  end)
end)
