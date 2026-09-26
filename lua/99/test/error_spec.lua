-- luacheck: globals describe it assert
---@diagnostic disable: undefined-field, duplicate-set-field
local Error = require("99.ops.error")
local Window = require("99.window")
local eq = assert.are.same

describe("ops.error", function()
  it("notifies one line by default", function()
    local original_notify = vim.notify
    local notifications = {}
    vim.notify = function(message, level)
      table.insert(notifications, { message, level })
    end

    Error.report({ display_errors = false }, "boom\nsecond line")

    vim.notify = original_notify
    eq(1, #notifications)
    eq({ "[99] boom second line", vim.log.levels.ERROR }, notifications[1])
  end)

  it("shows a compact float when display_errors is enabled", function()
    local original_uis = vim.api.nvim_list_uis
    vim.api.nvim_list_uis = function()
      return {
        { width = 120, height = 40 },
      }
    end
    local before = #Window.active_windows

    Error.report({ display_errors = true }, "boom")

    eq(before + 1, #Window.active_windows)
    Window.clear_active_popups()
    vim.api.nvim_list_uis = original_uis
  end)

  it("always shows the float for fatal reports", function()
    local original_uis = vim.api.nvim_list_uis
    vim.api.nvim_list_uis = function()
      return {
        { width = 120, height = 40 },
      }
    end
    local before = #Window.active_windows

    Error.report({ display_errors = false }, "boom", { fatal = true })

    eq(before + 1, #Window.active_windows)
    Window.clear_active_popups()
    vim.api.nvim_list_uis = original_uis
  end)
end)
